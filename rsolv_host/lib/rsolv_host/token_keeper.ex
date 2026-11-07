defmodule RsolvHost.TokenKeeper do
  @moduledoc """
  Holds the job's run token for the life of a role, and refreshes it with a fresh
  OIDC token before it expires (RFC-150 §1.2, ADR-074).

  The first exchange happens in the caller, so a refusal comes back from
  `start_link/1` as a plain error reason. Every token is masked in the log the
  moment it's received.

  Retry hand-off: the work workflow retries once on exit 3, and the platform
  allows one exchange per run attempt, issue and role. So after every exchange and
  refresh the keeper writes the token to a `0600` file under `$RUNNER_TEMP/rsolv`,
  which no sandbox mounts, and `resume: true` refreshes that token (the same-job
  path) instead of exchanging.
  """

  use GenServer

  alias RsolvHost.{ActionsLog, Oidc, Platform}

  @default_margin_s 300
  @default_retry_ms 30_000

  @type role :: :scan | :work | :publish
  @type served :: %{
          raw: String.t(),
          binding: map(),
          expires_at: DateTime.t(),
          req: Req.Request.t()
        }

  @doc """
  Exchanges (or, with `resume: true`, refreshes the hand-off token) and starts
  the keeper. Options: `:role`, `:issue` (`nil` for scan), `:env`, `:resume`,
  `:refresh_margin_s` (default 300), `:retry_ms` (default 30 s) and `:io`.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    state = %{
      role: Keyword.fetch!(opts, :role),
      issue: Keyword.get(opts, :issue),
      env: Keyword.fetch!(opts, :env),
      io: Keyword.get(opts, :io, :stdio),
      margin_s: Keyword.get(opts, :refresh_margin_s, @default_margin_s),
      retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms)
    }

    with {:ok, req} <- Platform.req(state.env),
         state = Map.put(state, :req, req),
         {:ok, token} <- first_token(state, Keyword.get(opts, :resume, false)) do
      callers = [self() | Process.get(:"$callers", [])]
      GenServer.start_link(__MODULE__, {state |> Map.merge(token) |> keep(), callers})
    end
  end

  @doc """
  The current run token with its binding and the platform request to use it with,
  or `{:error, :token_expired}` once it has expired unrefreshed.
  """
  @spec token(GenServer.server()) :: {:ok, served()} | {:error, :token_expired}
  def token(keeper), do: GenServer.call(keeper, :token)

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
  def init({state, callers}) do
    Process.put(:"$callers", callers)
    {:ok, schedule(state, refresh_delay_ms(state))}
  end

  @impl true
  def handle_call(:token, _from, state) do
    reply =
      if DateTime.compare(DateTime.utc_now(), state.expires_at) == :lt,
        do: {:ok, Map.take(state, [:raw, :binding, :expires_at, :req])},
        else: {:error, :token_expired}

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    case refresh(state, state.raw) do
      {:ok, token} ->
        {:noreply,
         state |> Map.merge(token) |> keep() |> then(&schedule(&1, refresh_delay_ms(&1)))}

      {:error, _reason} ->
        {:noreply, schedule(state, state.retry_ms)}
    end
  end

  defp first_token(state, false) do
    with {:ok, jwt} <- Oidc.fetch(state.env, io: state.io),
         do: Platform.exchange(state.req, jwt, state.issue)
  end

  defp first_token(state, true) do
    with {:ok, json} <- File.read(handoff_path(state.env, state.role, state.issue)),
         {:ok, %{"raw" => "rsolv_rt_" <> _ = raw}} <- RsolvCore.StrictJson.decode(json) do
      ActionsLog.mask(raw, state.io)
      refresh(state, raw)
    else
      {:error, {:platform, _status, _code}} = refused -> refused
      {:error, {:transport, _reason}} = transient -> transient
      _missing_or_unreadable -> {:error, :resume_unavailable}
    end
  end

  defp refresh(state, raw) do
    with {:ok, jwt} <- Oidc.fetch(state.env, io: state.io),
         do: Platform.refresh(state.req, raw, jwt)
  end

  # Masks the new token, then writes the hand-off file: emptied and made 0600
  # before the token is written, so it never sits in a readable file.
  defp keep(state) do
    ActionsLog.mask(state.raw, state.io)
    path = handoff_path(state.env, state.role, state.issue)
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    _ = File.rm(path)
    File.write!(path, "", [:exclusive])
    File.chmod!(path, 0o600)

    File.write!(
      path,
      JSON.encode!(%{
        raw: state.raw,
        expires_at: DateTime.to_iso8601(state.expires_at),
        binding: state.binding
      })
    )

    state
  end

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
