defmodule RsolvHost.TokenKeeper do
  @moduledoc """
  Holds the job's run token for the life of a role, and refreshes it with a fresh
  OIDC token before it expires (RFC-150 §1.2, ADR-074).

  The first exchange happens in the caller, so a refusal comes back from
  `start/1` as a plain error reason. Every token is masked in the log the
  moment it's received.

  Secrets in memory: the keeper keeps only the run token, the two OIDC request
  variables and the hand-off path, never the job's whole environment, and
  `format_status/1` redacts the token and the OIDC request token from
  `:sys.get_status/1` and crash reports. A BEAM crash dump would still hold
  them: the release must start the VM with crash dumps off
  (`ERL_CRASH_DUMP_SECONDS=0`), a packaging requirement (plan Task 27) that
  `rel/vm.args.eex` sets.

  Rotation: a refresh rotates the token on the platform (`Rsolv.Runners`), which
  refuses the old one from the moment it commits, with no grace period. So
  while a refresh is in flight, `token/1` waits for it (at most
  `:refresh_timeout_ms`, 10 s, after which the refresh is killed) and answers
  with the new token, never the one about to die. A refresh that failed
  without a definite refusal (lost answer, 5xx, timeout) may still have
  rotated the token: until a refresh succeeds, the keeper serves its request
  marked uncertain, and `RsolvHost.Platform` reports a 401 on it as
  `{:error, :token_uncertain}` (transient, exit 3), not as configuration.

  Retry hand-off: the work workflow retries once on exit 3, and the platform
  allows one exchange per run attempt, issue and role. So after every exchange and
  refresh the keeper writes the token to a `0600` file under `$RUNNER_TEMP/rsolv`,
  which no sandbox mounts, and `resume: true` refreshes that token (the same-job
  path) instead of exchanging. Without a hand-off file (the first exchange's
  answer was lost), the resume exchanges: if the lost exchange did happen, the
  platform refuses with `409 already_exchanged`, a transient failure.

  A lost refresh answer isn't recoverable within the job: the platform has
  rotated the token and the host never learned the new one. The next platform
  call gets 401 and exits 3; the retry refreshes the hand-off token (the old
  one), gets 401, and exits 3 too (`:token_uncertain`). Re-running the
  workflow starts over with a fresh exchange.
  """

  use GenServer

  alias RsolvHost.{ActionsLog, Oidc, Platform}

  @default_margin_s 300
  @default_retry_ms 30_000
  @default_refresh_timeout_ms 10_000
  # Longer than a refresh may take, so a waiting caller gets its answer.
  @call_timeout_ms 15_000
  @oidc_env ~w(ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN)

  @type role :: :scan | :work | :verify | :publish
  @type served :: %{
          raw: String.t(),
          binding: map(),
          expires_at: DateTime.t(),
          req: Req.Request.t()
        }

  @doc """
  Exchanges (or, with `resume: true`, refreshes the hand-off token) and starts
  the keeper. Options: `:role`, `:issue` (`nil` for scan), `:env`, `:resume`,
  `:refresh_margin_s` (default 300), `:retry_ms` (default 30 s),
  `:refresh_timeout_ms` (default 10 s) and `:io`.

  The keeper isn't linked to the caller: it monitors it and stops when it ends,
  and a keeper that has died is `{:error, :token_unavailable}` from `token/1`
  rather than an exit signal that takes the role down.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    env = Keyword.fetch!(opts, :env)

    state = %{
      path: handoff_path(env, Keyword.fetch!(opts, :role), Keyword.get(opts, :issue)),
      oidc: Map.take(env, @oidc_env),
      issue: Keyword.get(opts, :issue),
      io: Keyword.get(opts, :io, :stdio),
      margin_s: Keyword.get(opts, :refresh_margin_s, @default_margin_s),
      retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms),
      refresh_timeout_ms: Keyword.get(opts, :refresh_timeout_ms, @default_refresh_timeout_ms),
      refreshing: nil,
      waiting: [],
      uncertain: false
    }

    with {:ok, req} <- Platform.req(env),
         state = Map.put(state, :req, req),
         {:ok, token} <- first_token(state, Keyword.get(opts, :resume, false)),
         {:ok, state} <- state |> Map.merge(token) |> keep() do
      callers = [self() | Process.get(:"$callers", [])]
      GenServer.start(__MODULE__, {state, self(), callers})
    end
  end

  @doc """
  The current run token with its binding and the platform request to use it with.
  While a refresh is in flight, it waits for the refresh (see "Rotation").
  `{:error, :token_expired}` once it has expired unrefreshed; `{:error,
  :token_unavailable}` if the keeper is gone or doesn't answer within 15 s.
  """
  @spec token(GenServer.server()) ::
          {:ok, served()} | {:error, :token_expired | :token_unavailable}
  def token(keeper) do
    GenServer.call(keeper, :token, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :token_unavailable}
  end

  @doc "Stops the keeper and any refresh in flight. Safe to call on a keeper that's gone."
  @spec stop(GenServer.server()) :: :ok
  def stop(keeper) do
    GenServer.stop(keeper)
  catch
    :exit, _reason -> :ok
  end

  @doc "Where the retry hand-off token for `role` and `issue` lives."
  @spec handoff_path(map(), role(), pos_integer() | nil) :: Path.t()
  def handoff_path(env, role, issue),
    do:
      Path.join([
        Map.fetch!(env, "RUNNER_TEMP"),
        "rsolv",
        "run-token-#{role}#{issue && "-#{issue}"}.json"
      ])

  @doc "Deletes the hand-off token: the role ended in a way no retry resumes."
  @spec discard(map(), role(), pos_integer() | nil) :: :ok
  def discard(env, role, issue) do
    _ = File.rm(handoff_path(env, role, issue))
    :ok
  end

  @impl true
  def init({state, owner, callers}) do
    Process.put(:"$callers", callers)
    state = Map.put(state, :owner, Process.monitor(owner))
    {:ok, schedule(state, refresh_delay_ms(state))}
  end

  @impl true
  def handle_call(:token, from, %{refreshing: %Task{}} = state),
    do: {:noreply, %{state | waiting: [from | state.waiting]}}

  def handle_call(:token, _from, state), do: {:reply, served(state), state}

  defp served(state) do
    if DateTime.compare(DateTime.utc_now(), state.expires_at) == :lt do
      req =
        if state.uncertain,
          do: Req.Request.put_private(state.req, :token_uncertain, true),
          else: state.req

      {:ok, state |> Map.take([:raw, :binding, :expires_at]) |> Map.put(:req, req)}
    else
      {:error, :token_expired}
    end
  end

  # The refresh runs in a monitored task, bounded by `refresh_timeout_ms`, so
  # the keeper stays responsive and callers wait a bounded time.
  @impl true
  def handle_info(:refresh, %{refreshing: nil} = state) do
    request = Map.take(state, [:oidc, :io, :req, :raw])

    task =
      Task.Supervisor.async_nolink(RsolvHost.TaskSupervisor, fn ->
        refresh(request, request.raw)
      end)

    Process.send_after(self(), {:refresh_timeout, task.ref}, state.refresh_timeout_ms)
    {:noreply, %{state | refreshing: task}}
  end

  def handle_info({ref, result}, %{refreshing: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    refreshed(result, %{state | refreshing: nil})
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refreshing: %Task{ref: ref}} = state),
    do: refreshed({:error, :refresh_crashed}, %{state | refreshing: nil})

  def handle_info({:refresh_timeout, ref}, %{refreshing: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    refreshed({:error, :refresh_timeout}, %{state | refreshing: nil})
  end

  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  # A late reply from a refresh that was already given up on, or a stray message.
  def handle_info(_other, state), do: {:noreply, state}

  # A hand-off file that can't be written leaves the retry the older token; the
  # role goes on with the new one.
  defp refreshed({:ok, token}, state) do
    state = Map.merge(%{state | uncertain: false}, token)
    _kept_or_not = keep(state)
    {:noreply, state |> release() |> schedule(refresh_delay_ms(state))}
  end

  defp refreshed({:error, reason}, state) do
    state = %{state | uncertain: state.uncertain or uncertain?(reason)}
    {:noreply, state |> release() |> schedule(state.retry_ms)}
  end

  defp release(state) do
    Enum.each(state.waiting, &GenServer.reply(&1, served(state)))
    %{state | waiting: []}
  end

  # Only a definite refusal (4xx), or a failure before the platform was asked,
  # proves the token wasn't rotated.
  defp uncertain?({:platform, status, _code}) when status in 400..499, do: false
  defp uncertain?({:oidc_http, _status}), do: false
  defp uncertain?(:oidc_unavailable), do: false
  defp uncertain?(_lost_or_unknown), do: true

  @impl true
  def terminate(_reason, %{refreshing: %Task{} = task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @doc "Redacts the run token, the OIDC request token and any message or reason that may hold one."
  @impl true
  @spec format_status(map()) :: map()
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, &redact/1)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:reason, :redacted)
    |> Map.replace(:log, [])
  end

  defp redact(state) when is_map(state),
    do: state |> Map.replace(:raw, :redacted) |> Map.replace(:oidc, :redacted)

  defp redact(_state), do: :redacted

  defp first_token(state, false) do
    with {:ok, jwt} <- Oidc.fetch(state.oidc, io: state.io),
         do: Platform.exchange(state.req, jwt, state.issue)
  end

  defp first_token(state, true) do
    with {:ok, json} <- File.read(state.path),
         {:ok, %{"raw" => raw}} <- RsolvCore.StrictJson.decode(json),
         true <- Platform.run_token?(raw) do
      ActionsLog.mask(raw, state.io)
      state |> refresh(raw) |> resumed()
    else
      {:error, :enoent} -> first_token(state, false)
      _unreadable -> {:error, :resume_unavailable}
    end
  end

  # The first attempt's last refresh may have rotated the hand-off token with
  # its answer lost: a 401 on it is transient, not configuration.
  defp resumed({:error, {:platform, 401, _code}}), do: {:error, :token_uncertain}
  defp resumed(result), do: result

  defp refresh(state, raw) do
    with {:ok, jwt} <- Oidc.fetch(state.oidc, io: state.io),
         do: Platform.refresh(state.req, raw, jwt)
  end

  # Masks the new token, then writes the hand-off file: emptied and made 0600
  # before the token is written, so it never sits in a readable file. A file
  # error is `{:error, {:handoff, posix}}`, never a raise carrying the path.
  defp keep(state) do
    ActionsLog.mask(state.raw, state.io)
    dir = Path.dirname(state.path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         _removed_or_absent = File.rm(state.path),
         :ok <- File.write(state.path, "", [:exclusive]),
         :ok <- File.chmod(state.path, 0o600),
         :ok <- File.write(state.path, handoff_json(state)) do
      {:ok, state}
    else
      {:error, reason} -> {:error, {:handoff, reason}}
    end
  end

  defp handoff_json(state),
    do:
      JSON.encode!(%{
        raw: state.raw,
        expires_at: DateTime.to_iso8601(state.expires_at),
        binding: state.binding
      })

  defp refresh_delay_ms(state) do
    state.expires_at
    |> DateTime.add(-state.margin_s)
    |> DateTime.diff(DateTime.utc_now(), :millisecond)
    |> max(0)
  end

  defp schedule(state, delay_ms) do
    Process.send_after(self(), :refresh, delay_ms)
    state
  end
end
