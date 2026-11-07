defmodule RsolvHost.DripServer do
  @moduledoc """
  A real HTTP/1.1 server on 127.0.0.1 that answers over time, for the
  deadlines `Req.Test` can't show: its plug adapter hands over a whole body at
  once and ignores `receive_timeout`. One request per connection.

  `handler.(method, path)` answers with:

    * `{:json, status, map}`, or `{:json, status, map, headers}`;
    * `{:drip, chunk, every_ms, count}`: a 200 event stream that sends `chunk`
      `count` times, `every_ms` apart, then closes;
    * `{:hang, ms}`: reads the request, then says nothing for `ms` and closes.
  """

  @doc "Starts the server, linked to the caller, and returns its port."
  @spec start((String.t(), String.t() -> tuple())) :: :inet.port_number()
  def start(handler) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    acceptor = spawn_link(fn -> accept(listen, handler) end)
    :ok = :gen_tcp.controlling_process(listen, acceptor)
    port
  end

  @doc "A `Req` request for the server, with the platform client's retry policy."
  @spec req(:inet.port_number()) :: Req.Request.t()
  def req(port),
    do:
      Req.new(
        base_url: "http://127.0.0.1:#{port}",
        retry: &RsolvHost.Platform.retry/2,
        retry_log_level: false,
        redirect: false,
        raw: true
      )

  defp accept(listen, handler) do
    {:ok, socket} = :gen_tcp.accept(listen)
    pid = spawn(fn -> receive(do: (:go -> serve(socket, handler))) end)
    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :go)
    accept(listen, handler)
  end

  defp serve(socket, handler) do
    {method, path} = read_request(socket)

    case handler.(method, path) do
      {:json, status, map} -> json(socket, status, map, [])
      {:json, status, map, headers} -> json(socket, status, map, headers)
      {:drip, chunk, every_ms, count} -> drip(socket, chunk, every_ms, count)
      {:hang, ms} -> Process.sleep(ms)
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    :ok = :inet.setopts(socket, packet: :http_bin)
    {:ok, {:http_request, method, {:abs_path, path}, _version}} = :gen_tcp.recv(socket, 0)
    length = headers(socket, 0)
    :ok = :inet.setopts(socket, packet: :raw)
    if length > 0, do: {:ok, _body} = :gen_tcp.recv(socket, length)
    {to_string(method), path |> URI.parse() |> Map.fetch!(:path)}
  end

  defp headers(socket, length) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _, :"Content-Length", _, value}} ->
        headers(socket, String.to_integer(value))

      {:ok, {:http_header, _, _name, _, _value}} ->
        headers(socket, length)

      {:ok, :http_eoh} ->
        length
    end
  end

  defp json(socket, status, map, headers) do
    body = JSON.encode!(map)
    extra = Enum.map_join(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\ncontent-length: " <>
        "#{byte_size(body)}\r\nconnection: close\r\n#{extra}\r\n#{body}"
    )
  end

  defp drip(socket, chunk, every_ms, count) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
        "transfer-encoding: chunked\r\nconnection: close\r\n\r\n"
    )

    Enum.reduce_while(1..count//1, :ok, fn _n, :ok ->
      frame = Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n"

      case :gen_tcp.send(socket, frame) do
        :ok ->
          Process.sleep(every_ms)
          {:cont, :ok}

        {:error, _closed} ->
          {:halt, :ok}
      end
    end)
  end
end

defmodule RsolvHost.StaticKeeper do
  @moduledoc "Answers `RsolvHost.TokenKeeper.token/1` with a fixed `req`, for a real server."
  use GenServer

  @doc "Starts a keeper serving `req`, linked to the caller."
  @spec start_link(Req.Request.t()) :: GenServer.on_start()
  def start_link(req), do: GenServer.start_link(__MODULE__, req)

  @impl true
  def init(req), do: {:ok, req}

  @impl true
  def handle_call(:token, _from, req) do
    {:reply,
     {:ok,
      %{
        req: req,
        raw: "rsolv_rt_" <> String.duplicate("A", 43),
        binding: %{},
        expires_at: DateTime.add(DateTime.utc_now(), 3_600)
      }}, req}
  end
end
