defmodule RsolvHost.ScanRelay do
  @moduledoc """
  Serves the scanner in the scan sandbox (ADR-077 §4). The scanner's platform and
  GitHub calls arrive as frames (`{"call": name, "args": {...}}`) on its stdin
  and stdout; the host answers each with `{"ok": result}` or `{"error": message}`
  from a fixed allowlist, so the sandbox holds neither the run token nor
  `GITHUB_TOKEN`, and has no network.

  Issue titles and bodies are rendered inside the sandbox (owner decision 2), so
  they are untrusted: the host caps their size, allows only the labels
  `IssueCreator` produces, and caps the number of issues, counting every
  creation attempted (a creation whose answer was lost may still have happened). A policy refusal is
  answered and the relay goes on; a refusal from the platform or GitHub ends it
  with that error. `done` may name at most `max_issues` issues, existing ones
  included. `list_issues` answers with each issue's `number`, `title`,
  `state`, `html_url` and label names only.

  The frame channel is the scanner's stdout and stderr merged (a Port can't
  read stderr apart, and an inherited stderr would be the Actions log), so the
  Sandbox CLI contract is that `rsolv-sandbox scan` writes nothing to fd 2: it
  points fd 2 at `/dev/null` (or a file) before it runs anything. Any other
  byte breaks the framing and ends the scan as a sandbox failure (exit 4).

  Limits: 2,000 frames, 30 minutes for the whole conversation (checked before
  each frame and bounding every write to the scanner), 16 MiB per frame.
  """

  alias RsolvCore.Text
  alias RsolvHost.{Frame, GitHub, Platform, TokenKeeper}

  @max_frame_bytes 16 * 1024 * 1024
  @max_frames 2_000
  @max_duration_ms 30 * 60 * 1_000
  @languages ~w(javascript typescript python ruby java php elixir)
  @fixed_labels ~w(security automated-scan critical high medium low)
  @label ~r/\Arsolv:(detected|vuln-[a-z0-9_-]{1,40}|cwe-(CWE-)?[0-9]{1,5})\z/
  @max_validate_bytes 8 * 1024 * 1024
  @max_validate_calls 20
  @max_create_calls 50
  @max_list_pages 10
  @max_labels_per_call 20
  @max_title_bytes 256
  @max_body_bytes 65_536
  @max_done_issues 50

  @doc """
  The relay's state. Options: `:channel` (the scanner's Port), `:exec` (its
  `RsolvHost.Exec` module), `:keeper`, `:github`, `:repository`,
  `:max_issues` and `:deadline` (monotonic milliseconds; default 30 minutes
  from now).
  """
  @spec new(keyword()) :: map()
  def new(opts) do
    %{
      channel: Keyword.fetch!(opts, :channel),
      exec: Keyword.fetch!(opts, :exec),
      keeper: Keyword.fetch!(opts, :keeper),
      github: Keyword.fetch!(opts, :github),
      repository: Keyword.fetch!(opts, :repository),
      max_issues: Keyword.fetch!(opts, :max_issues),
      deadline:
        Keyword.get_lazy(opts, :deadline, fn ->
          System.monotonic_time(:millisecond) + @max_duration_ms
        end),
      buffer: "",
      frames: 0,
      validate_calls: 0,
      create_calls: 0,
      created: 0,
      known: MapSet.new()
    }
  end

  @doc "Whether `label` is one the scanner may put on an issue."
  @spec allowed_label?(term()) :: boolean()
  def allowed_label?(label) when label in @fixed_labels, do: true
  def allowed_label?(label) when is_binary(label), do: label =~ @label
  def allowed_label?(_label), do: false

  @doc "Serves frames until `done` (returning its args) or an error."
  @spec serve(map()) :: {:ok, map()} | {:error, term()}
  def serve(%{channel: channel} = state) do
    receive do
      {^channel, {:data, data}} -> frames(%{state | buffer: state.buffer <> data})
      {^channel, {:exit_status, _status}} -> {:error, {:sandbox, :scanner_exited}}
    after
      max(state.deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, {:sandbox, :scan_timeout}}
    end
  end

  # The deadline is checked before each buffered frame too: a scanner that keeps
  # the mailbox full never reaches `serve/1`'s `after`.
  defp frames(state) do
    if System.monotonic_time(:millisecond) >= state.deadline,
      do: {:error, {:sandbox, :scan_timeout}},
      else: frame(state)
  end

  defp frame(state) do
    case Frame.decode(state.buffer, @max_frame_bytes) do
      :more ->
        serve(state)

      {:error, reason} ->
        {:error, reason}

      {:ok, _frame, _rest} when state.frames >= @max_frames ->
        {:error, :frame_limit}

      {:ok, frame, rest} ->
        frame |> call(%{state | buffer: rest, frames: state.frames + 1}) |> next()
    end
  end

  defp next({:reply, reply, state}) do
    case state.exec.command(state.channel, Frame.encode(reply), state.deadline) do
      :ok -> frames(state)
      {:error, :timeout} -> {:error, {:sandbox, :scan_timeout}}
      {:error, :closed} -> {:error, {:sandbox, :scanner_exited}}
    end
  end

  defp next({:done, args}), do: {:ok, args}
  defp next({:error, _reason} = error), do: error

  defp call(%{"call" => name, "args" => %{} = args} = frame, state) when map_size(frame) == 2,
    do: handle(name, args, state)

  defp call(%{"call" => name} = frame, state) when map_size(frame) == 1,
    do: handle(name, %{}, state)

  defp call(_malformed, _state), do: {:error, :bad_frame}

  defp handle("patterns", %{"language" => language}, state) when language in @languages,
    do: platform(state, &Platform.patterns(&1, &2, language))

  defp handle("severity_tiers", _args, state), do: platform(state, &Platform.severity_tiers/2)

  defp handle("validate", _args, %{validate_calls: @max_validate_calls} = state),
    do: refuse(state, "call limit")

  defp handle("validate", %{"body" => %{} = body}, state) do
    if byte_size(JSON.encode!(body)) <= @max_validate_bytes,
      do:
        platform(
          %{state | validate_calls: state.validate_calls + 1},
          &Platform.validate(&1, &2, body)
        ),
      else: refuse(state, "invalid arguments")
  end

  defp handle("plan", %{"body" => %{} = body}, state),
    do: platform(state, &Platform.scan_plan(&1, &2, Map.put(body, "namespace", state.repository)))

  defp handle("list_issues", %{"labels" => [_ | _] = labels}, state) do
    if Enum.all?(labels, &allowed_label?/1),
      do: list_issues(state, labels, 1, []),
      else: refuse(state, "label not allowed")
  end

  defp handle("ensure_labels", %{"labels" => [_ | _] = labels}, state)
       when length(labels) <= @max_labels_per_call do
    cond do
      not Enum.all?(labels, &label?/1) -> refuse(state, "invalid arguments")
      not Enum.all?(labels, &allowed_label?(&1["name"])) -> refuse(state, "label not allowed")
      true -> ensure_labels(state, Enum.uniq(labels))
    end
  end

  defp handle("create_issue", _args, %{create_calls: @max_create_calls} = state),
    do: refuse(state, "issue limit")

  defp handle("create_issue", _args, %{created: created, max_issues: created} = state),
    do: refuse(state, "issue limit")

  defp handle(
         "create_issue",
         %{"title" => title, "body" => body, "labels" => labels} = args,
         state
       )
       when map_size(args) == 3 do
    state = %{state | create_calls: state.create_calls + 1}

    cond do
      not issue?(title, body, labels) -> refuse(state, "invalid arguments")
      not Enum.all?(labels, &allowed_label?/1) -> refuse(state, "label not allowed")
      true -> create_issue(%{state | created: state.created + 1}, args)
    end
  end

  defp handle("done", %{"issues" => issues}, %{max_issues: max})
       when is_list(issues) and length(issues) > max,
       do: {:error, :too_many_issues}

  defp handle("done", %{"issues" => issues} = args, state)
       when is_list(issues) and length(issues) <= @max_done_issues do
    if Enum.all?(issues, &match?(%{"number" => n} when is_integer(n), &1)) and
         Enum.all?(issues, &MapSet.member?(state.known, &1["number"])),
       do: {:done, args},
       else: {:error, :unknown_issue}
  end

  defp handle(name, _args, state)
       when name in ~w(patterns validate plan list_issues ensure_labels create_issue done),
       do: refuse(state, "invalid arguments")

  defp handle(_unknown, _args, state), do: refuse(state, "unknown call")

  defp refuse(state, message), do: {:reply, %{"error" => message}, state}

  defp platform(state, fun) do
    with {:ok, %{req: req, raw: raw}} <- TokenKeeper.token(state.keeper),
         {:ok, result} <- fun.(req, raw) do
      {:reply, %{"ok" => result}, state}
    end
  end

  defp list_issues(state, labels, page, acc) do
    case GitHub.list_issues(state.github, labels, page) do
      {:ok, items} when length(items) == 100 and page < @max_list_pages ->
        list_issues(state, labels, page + 1, [acc, trimmed(items)])

      {:ok, items} ->
        issues = List.flatten([acc, trimmed(items)])
        known = Enum.reduce(issues, state.known, &MapSet.put(&2, &1["number"]))
        {:reply, %{"ok" => issues}, %{state | known: known}}

      error ->
        error
    end
  end

  defp trimmed(items) do
    for %{"number" => number} = item <- items,
        is_integer(number),
        not Map.has_key?(item, "pull_request") do
      %{
        "number" => number,
        "title" => item["title"],
        "state" => item["state"],
        "html_url" => item["html_url"],
        "labels" => for(%{"name" => name} <- List.wrap(item["labels"]), do: name)
      }
    end
  end

  defp label?(%{"name" => name, "color" => color, "description" => description} = label)
       when map_size(label) == 3 and is_binary(name) and is_binary(color) and
              is_binary(description),
       do:
         color =~ ~r/\A[0-9a-f]{6}\z/ and byte_size(description) <= 100 and
           Text.plain?(description)

  defp label?(_label), do: false

  defp ensure_labels(state, labels) do
    Enum.reduce_while(labels, {:reply, %{"ok" => true}, state}, fn label, reply ->
      case GitHub.create_label(state.github, label) do
        :ok -> {:cont, reply}
        error -> {:halt, error}
      end
    end)
  end

  # A zero-width space after `@` keeps the text readable but stops GitHub
  # notifying the user or team. An `@` inside a word, an email or a URL path
  # isn't a mention and is left alone; links are kept as they are. GitHub finds
  # mentions in the rendered text, where `&#64;` and its kin are already `@`,
  # so those, and the wide at-signs, become a plain `@` first.
  defp unmention(body) do
    body
    |> String.replace(~r/&(?:#0*64|#[xX]0*40|commat);?|\x{FF20}|\x{FE6B}/u, "@")
    |> String.replace(~r/(?<![\w\/.-])@(?=[A-Za-z0-9])/u, "@\u200B")
  end

  defp issue?(title, body, labels)
       when is_binary(title) and is_binary(body) and is_list(labels) do
    byte_size(title) in 1..@max_title_bytes and Text.plain?(title) and
      byte_size(body) <= @max_body_bytes and
      String.valid?(body) and not String.contains?(body, <<0>>) and length(labels) in 1..10 and
      Enum.uniq(labels) == labels
  end

  defp issue?(_title, _body, _labels), do: false

  defp create_issue(state, args) do
    case GitHub.create_issue(state.github, Map.update!(args, "body", &unmention/1)) do
      {:ok, %{"number" => number} = issue} when is_integer(number) ->
        reply = %{"ok" => %{"number" => number, "html_url" => issue["html_url"]}}

        {:reply, reply, %{state | known: MapSet.put(state.known, number)}}

      {:ok, _malformed} ->
        {:error, :malformed_response}

      error ->
        error
    end
  end
end
