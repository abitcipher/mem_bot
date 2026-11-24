defmodule MemBot do
  @moduledoc """
  A client for the local link of `mem-botd`, the MEM node of a Mini App's service.

  The node does everything MEM does: keys, end-to-end encryption, the hub, couriers. This
  client only exchanges JSON with it over a WebSocket on the same machine:

    * the node sends `hello` (the service's pairing card) and a `request` for each user request;
    * the client answers with `update`s. An answer names the request in `in_reply_to`; a push
      names none (the node sends at most 32 pushes a day to each user).

  A user is a 64-hex-digit persona: the user's identity for this service only, never their MEM
  identity, and different for every service.

  Start it under your supervisor with a module implementing `c:handle_request/3`:

      children = [
        {MemBot, url: "ws://127.0.0.1:4100/", token: token, handler: MyService.MiniApp}
      ]

  Options:

    * `:token` (required): the node's bearer token;
    * `:handler` (required): the module implementing this behaviour;
    * `:url`: the node's address (default `"ws://127.0.0.1:4100/"`);
    * `:name`: the registered name (default `MemBot`).

  Data and bodies are JSON values without floats, nested at most eight levels deep: MEM's wire
  format carries no more. Bodies are checked before sending (see `MemBot.Value`).

  The link is specified in MEM's `spec/botd-link.md` (CC BY 4.0).
  """

  use GenServer
  require Logger

  alias MemBot.Value

  @typedoc "A user's persona: 64 lower-case hex digits."
  @type user :: String.t()

  @typedoc "What an update carries: new screen state (an object) or data for a web page."
  @type kind :: :state | :data

  @doc """
  Handles one user's request. Return `{:reply, body}` to answer with a state update (a map),
  `{:reply, :data, body}` to answer with a data update, or `:noreply`.

  Runs inside the client's process: keep it short, or hand the work to another process and
  answer later with `push/4`.
  """
  @callback handle_request(user :: user(), action :: String.t(), data :: term()) ::
              {:reply, map()} | {:reply, :data, term()} | :noreply

  @retry_ms 1_000
  @max_retry_ms 30_000

  defstruct [
    :url,
    :token,
    :handler,
    :conn,
    :ref,
    :websocket,
    :status,
    :resp_headers,
    card: nil,
    next_ref: 1,
    waiting: %{},
    retry_ms: @retry_ms
  ]

  @doc "Starts the client. It connects at once and reconnects when the link drops."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Pushes `body` to `user`: an update nobody asked for. Returns `:ok` once the node accepted it
  for sending, or `{:error, reason}`: `:not_connected`, `:disconnected`, a `MemBot.Value`
  error, `:state_not_an_object`, or the node's reason (a string).
  """
  @spec push(GenServer.server(), user(), term(), kind()) :: :ok | {:error, term()}
  def push(server \\ __MODULE__, user, body, kind \\ :state) when kind in [:state, :data] do
    with :ok <- check_body(kind, body) do
      GenServer.call(server, {:update, user, nil, kind, body})
    end
  end

  @doc "The service's pairing card (`memcard0:` text), once the node has sent it."
  @spec card(GenServer.server()) :: String.t() | nil
  def card(server \\ __MODULE__), do: GenServer.call(server, :card)

  @doc "Whether the link to the node is up."
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server \\ __MODULE__), do: GenServer.call(server, :connected?)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      url: Keyword.get(opts, :url, "ws://127.0.0.1:4100/"),
      token: Keyword.fetch!(opts, :token),
      handler: Keyword.fetch!(opts, :handler)
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:card, _from, state), do: {:reply, state.card, state}
  def handle_call(:connected?, _from, state), do: {:reply, state.websocket != nil, state}

  def handle_call({:update, user, in_reply_to, kind, body}, from, state) do
    case send_update(state, user, in_reply_to, kind, body) do
      {:ok, ref, state} -> {:noreply, put_in(state.waiting[ref], from)}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:connect, state) do
    uri = URI.parse(state.url)
    headers = [{"authorization", "Bearer " <> state.token}]
    path = if uri.path in [nil, ""], do: "/", else: uri.path

    with {:ok, conn} <- Mint.HTTP.connect(:http, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers) do
      {:noreply, %{state | conn: conn, ref: ref}}
    else
      {:error, reason} -> retry(state, reason)
      {:error, conn, reason} -> retry(%{state | conn: conn}, reason)
    end
  end

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} -> handle_responses(%{state | conn: conn}, responses)
      {:error, conn, reason, _} -> retry(%{state | conn: conn}, reason)
      :unknown -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_responses(state, responses) do
    Enum.reduce_while(responses, {:noreply, state}, fn response, {:noreply, state} ->
      case handle_response(state, response) do
        {:ok, state} -> {:cont, {:noreply, state}}
        {:stop, reason, state} -> {:halt, retry(state, reason)}
      end
    end)
  end

  defp handle_response(%{ref: ref} = state, {:status, ref, status}),
    do: {:ok, %{state | status: status}}

  defp handle_response(%{ref: ref} = state, {:headers, ref, headers}),
    do: {:ok, %{state | resp_headers: headers}}

  defp handle_response(%{ref: ref, websocket: nil} = state, {:done, ref}) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        {:ok, %{state | conn: conn, websocket: websocket, retry_ms: @retry_ms}}

      # 401: wrong token; 409: another service is connected.
      {:error, conn, reason} ->
        {:stop, reason, %{state | conn: conn}}
    end
  end

  defp handle_response(%{ref: ref, websocket: ws} = state, {:data, ref, data}) when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> handle_frames(%{state | websocket: ws}, frames)
      {:error, _ws, reason} -> {:stop, reason, state}
    end
  end

  defp handle_response(state, _other), do: {:ok, state}

  defp handle_frames(state, frames) do
    Enum.reduce_while(frames, {:ok, state}, fn
      {:text, text}, {:ok, state} ->
        case Jason.decode(text) do
          {:ok, message} -> {:cont, {:ok, handle_message(state, message)}}
          {:error, _} -> {:cont, {:ok, state}}
        end

      {:ping, data}, {:ok, state} ->
        case send_frame(state, {:pong, data}) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, reason, state} -> {:halt, {:stop, reason, state}}
        end

      {:close, _code, reason}, {:ok, state} ->
        {:halt, {:stop, {:closed, reason}, state}}

      _frame, acc ->
        {:cont, acc}
    end)
  end

  defp handle_message(state, %{"type" => "hello", "card" => card}) do
    Logger.info("MemBot: linked to the MEM node")
    %{state | card: card}
  end

  defp handle_message(state, %{
         "type" => "request",
         "user" => user,
         "id" => id,
         "action" => action,
         "data" => data
       }) do
    answer =
      try do
        state.handler.handle_request(user, action, data)
      rescue
        e ->
          Logger.error("MemBot: handler failed on #{inspect(action)}: " <> Exception.message(e))
          :noreply
      end

    case answer do
      {:reply, body} -> reply(state, user, id, :state, body)
      {:reply, :data, body} -> reply(state, user, id, :data, body)
      :noreply -> state
    end
  end

  defp handle_message(state, %{"type" => type} = m) when type in ["ok", "error"] do
    {from, waiting} = Map.pop(state.waiting, m["ref"])
    result = if type == "ok", do: :ok, else: {:error, m["reason"]}

    case from do
      nil -> if type == "error", do: Logger.warning("MemBot: update refused: #{m["reason"]}")
      from -> GenServer.reply(from, result)
    end

    %{state | waiting: waiting}
  end

  defp handle_message(state, _message), do: state

  # Answers from the handler: nobody waits for them, so a refusal is only logged.
  defp reply(state, user, id, kind, body) do
    with :ok <- check_body(kind, body),
         {:ok, _ref, state} <- send_update(state, user, id, kind, body) do
      state
    else
      {:error, reason, state} ->
        Logger.warning("MemBot: answer not sent: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.warning("MemBot: answer not sent: #{inspect(reason)}")
        state
    end
  end

  defp check_body(:state, body) when not is_map(body), do: {:error, :state_not_an_object}
  defp check_body(_kind, body), do: Value.check(body)

  defp send_update(%{websocket: nil} = state, _user, _id, _kind, _body),
    do: {:error, :not_connected, state}

  defp send_update(state, user, in_reply_to, kind, body) do
    ref = state.next_ref

    message =
      %{type: "update", user: user, kind: kind, body: body, ref: ref}
      |> then(fn m -> if in_reply_to, do: Map.put(m, :in_reply_to, in_reply_to), else: m end)

    case send_frame(%{state | next_ref: ref + 1}, {:text, Jason.encode!(message)}) do
      {:ok, state} -> {:ok, ref, state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp send_frame(state, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | websocket: ws, conn: conn}}
    else
      {:error, %Mint.WebSocket{} = ws, reason} -> {:error, reason, %{state | websocket: ws}}
      {:error, conn, reason} -> {:error, reason, %{state | conn: conn}}
    end
  end

  defp retry(state, reason) do
    Logger.warning("MemBot: link to the MEM node down (#{inspect(reason)}); retrying")
    if state.conn, do: Mint.HTTP.close(state.conn)

    for {_ref, from} <- state.waiting, do: GenServer.reply(from, {:error, :disconnected})

    Process.send_after(self(), :connect, state.retry_ms)

    {:noreply,
     %{
       state
       | conn: nil,
         ref: nil,
         websocket: nil,
         status: nil,
         resp_headers: nil,
         waiting: %{},
         retry_ms: min(state.retry_ms * 2, @max_retry_ms)
     }}
  end
end
