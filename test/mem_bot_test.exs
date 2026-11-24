defmodule MemBotTest do
  use ExUnit.Case, async: false

  @token "secret-token"
  @user String.duplicate("ab", 32)
  @id String.duplicate("cd", 16)

  defmodule Node do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(%{test: test}) do
      send(test, {:node, self()})
      {:push, {:text, Jason.encode!(%{type: "hello", card: "memcard0:TEST"})}, %{test: test}}
    end

    @impl true
    def handle_in({text, opcode: :text}, state) do
      send(state.test, {:from_service, Jason.decode!(text)})
      {:ok, state}
    end

    @impl true
    def handle_info({:send, message}, state), do: {:push, {:text, Jason.encode!(message)}, state}
    def handle_info(:close, state), do: {:stop, :normal, state}
  end

  defmodule NodePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, %{test: test, token: token}) do
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> ^token] ->
          conn
          |> WebSockAdapter.upgrade(MemBotTest.Node, %{test: test}, [])
          |> Plug.Conn.halt()

        _ ->
          send(test, :unauthorized)
          Plug.Conn.send_resp(conn, 401, "")
      end
    end
  end

  defmodule Handler do
    @moduledoc false
    @behaviour MemBot

    @impl true
    def handle_request(user, "count", %{"value" => codes}) do
      send(:persistent_term.get(:mem_bot_test), {:handled, user, codes})
      {:reply, %{"counted" => length(codes)}}
    end

    def handle_request(_user, "report", _data), do: {:reply, :data, ["a", "b"]}
    def handle_request(_user, "float", _data), do: {:reply, %{"t" => 4.5}}
    def handle_request(_user, "boom", _data), do: raise("broken handler")
    def handle_request(_user, _action, _data), do: :noreply
  end

  defmodule IdHandler do
    @moduledoc false
    @behaviour MemBot

    @impl true
    def handle_request(user, id, "later", _data) do
      send(:persistent_term.get(:mem_bot_test), {:later, user, id})
      :noreply
    end

    def handle_request(_user, id, _action, _data), do: {:reply, %{"id" => id}}
  end

  setup do
    :persistent_term.put(:mem_bot_test, self())

    {:ok, server} =
      Bandit.start_link(
        plug: {NodePlug, %{test: self(), token: @token}},
        ip: :loopback,
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "ws://127.0.0.1:#{port}/"}
  end

  defp start(url, token \\ @token, handler \\ Handler) do
    name = :"bot_#{System.unique_integer([:positive])}"
    start_supervised!({MemBot, url: url, token: token, handler: handler, name: name})
    name
  end

  defp linked(url, handler \\ Handler) do
    bot = start(url, @token, handler)
    assert_receive {:node, node}
    wait_until(fn -> MemBot.card(bot) == "memcard0:TEST" end)
    {bot, node}
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "connects with the token and learns the service's card", %{url: url} do
    {bot, _node} = linked(url)
    assert MemBot.connected?(bot)
  end

  test "a request goes to the handler and its answer back to the node", %{url: url} do
    {_bot, node} = linked(url)

    send(
      node,
      {:send,
       %{
         type: "request",
         user: @user,
         id: @id,
         action: "count",
         data: %{"value" => [%{"text" => "A"}, %{"text" => "B"}]}
       }}
    )

    assert_receive {:handled, @user, [_, _]}
    assert_receive {:from_service, update}

    assert %{
             "type" => "update",
             "user" => @user,
             "in_reply_to" => @id,
             "kind" => "state",
             "body" => %{"counted" => 2},
             "ref" => ref
           } = update

    assert is_integer(ref)
  end

  test "a handler with the request's id gets it, and may answer later", %{url: url} do
    {bot, node} = linked(url, IdHandler)
    send(node, {:send, %{type: "request", user: @user, id: @id, action: "ask", data: %{}}})
    assert_receive {:from_service, %{"in_reply_to" => @id, "body" => %{"id" => @id}}}

    later = String.duplicate("b", 32)
    send(node, {:send, %{type: "request", user: @user, id: later, action: "later", data: %{}}})
    assert_receive {:later, @user, ^later}
    refute_receive {:from_service, _}, 100

    task = Task.async(fn -> MemBot.answer(bot, @user, later, %{"done" => true}) end)

    assert_receive {:from_service,
                    %{"in_reply_to" => ^later, "ref" => ref, "body" => %{"done" => true}}}

    send(node, {:send, %{type: "ok", ref: ref}})
    assert Task.await(task) == :ok
    assert MemBot.answer(bot, @user, later, %{"t" => 1.5}) == {:error, :float}
  end

  test "a data answer is sent as data", %{url: url} do
    {_bot, node} = linked(url)
    send(node, {:send, %{type: "request", user: @user, id: @id, action: "report", data: %{}}})
    assert_receive {:from_service, %{"kind" => "data", "body" => ["a", "b"]}}
  end

  test "an answer without a wire form and a failing handler send nothing", %{url: url} do
    {bot, node} = linked(url)
    send(node, {:send, %{type: "request", user: @user, id: @id, action: "float", data: %{}}})
    send(node, {:send, %{type: "request", user: @user, id: @id, action: "boom", data: %{}}})
    send(node, {:send, %{type: "request", user: @user, id: @id, action: "report", data: %{}}})
    # Only the third request is answered, and the client is still linked.
    assert_receive {:from_service, %{"kind" => "data"}}
    refute_receive {:from_service, _}, 100
    assert MemBot.connected?(bot)
  end

  test "a push waits for the node's ok or error", %{url: url} do
    {bot, node} = linked(url)
    task = Task.async(fn -> MemBot.push(bot, @user, %{"recall" => "LOT42"}) end)
    assert_receive {:from_service, %{"type" => "update", "ref" => ref} = push}
    refute Map.has_key?(push, "in_reply_to")
    send(node, {:send, %{type: "ok", ref: ref}})
    assert Task.await(task) == :ok

    task = Task.async(fn -> MemBot.push(bot, @user, %{"recall" => "LOT43"}) end)
    assert_receive {:from_service, %{"ref" => ref}}
    send(node, {:send, %{type: "error", ref: ref, reason: "push limit"}})
    assert Task.await(task) == {:error, "push limit"}
  end

  test "a push without a wire form is refused before sending", %{url: url} do
    {bot, _node} = linked(url)
    assert MemBot.push(bot, @user, %{"t" => 4.5}) == {:error, :float}
    assert MemBot.push(bot, @user, ["not", "an", "object"]) == {:error, :state_not_an_object}
    refute_receive {:from_service, _}, 100
  end

  test "a hello sent in the same packet as the upgrade's answer is not lost" do
    # A node that writes the 101 answer and its first frame at once, as mem-botd may.
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, request} = recv_headers(socket, "")
      [_, key] = Regex.run(~r/sec-websocket-key: *(\S+)/i, request)

      accept =
        :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

      hello = Jason.encode!(%{type: "hello", card: "memcard0:EARLY"})

      :ok =
        :gen_tcp.send(socket, [
          "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n",
          "sec-websocket-accept: #{accept}\r\n\r\n",
          <<0x81, byte_size(hello)>>,
          hello
        ])

      Process.sleep(:infinity)
    end)

    bot = start("ws://127.0.0.1:#{port}/")
    wait_until(fn -> MemBot.card(bot) == "memcard0:EARLY" end)
  end

  defp recv_headers(socket, acc) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    acc = acc <> data
    if String.contains?(acc, "\r\n\r\n"), do: {:ok, acc}, else: recv_headers(socket, acc)
  end

  test "a wrong token never links", %{url: url} do
    bot = start(url, "wrong")
    assert_receive :unauthorized
    refute MemBot.connected?(bot)
    assert MemBot.push(bot, @user, %{}) == {:error, :not_connected}
  end

  test "it reconnects when the node closes the link", %{url: url} do
    {bot, node} = linked(url)
    send(node, :close)
    assert_receive {:node, _again}, 3_000
    wait_until(fn -> MemBot.connected?(bot) end)
  end
end
