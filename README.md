## MemBot — Elixir client for a MEM Mini App's service node

A [MEM](https://github.com/abitcipher/mem_common) Mini App talks to its **service** end to end,
over whatever channel exists: the local network, Bluetooth, other phones carrying messages, or a
hub. The service never handles MEM keys or channels. A headless MEM node, `mem-botd`, runs next
to it, and the service talks to that node over a local WebSocket with JSON.

MemBot is that service-side client: it connects to the node, hands each user request to your
handler, sends your answers and pushes, and reconnects when the link drops.

### Use

```elixir
{:mem_bot, "~> 0.1"}
```

```elixir
defmodule MyService.MiniApp do
  @behaviour MemBot

  @impl true
  def handle_request(user, "count", %{"value" => codes}) do
    # `user` is the persona of this user for your service, never their MEM identity.
    {:reply, %{"counted" => length(codes)}}
  end

  def handle_request(_user, _action, _data), do: :noreply
end

children = [
  {MemBot, url: "ws://127.0.0.1:4100/", token: System.fetch_env!("MEM_BOTD_TOKEN"),
   handler: MyService.MiniApp}
]
```

Later, without a request:

```elixir
:ok = MemBot.push(user, %{"recall" => "LOT42"})
MemBot.card()   # the service's pairing card, for the Mini App's package
```

Values have no floats and nest at most eight levels: MEM's wire format carries no more.
`MemBot.Value.check/1` tells you before anything is sent.

The local link is specified in MEM's `spec/botd-link.md` (CC BY 4.0); the node's own
documentation is in the Mini App guide.

### Develop

```sh
mix deps.get
mix test
mix format --check-formatted
```

### License

[MIT](LICENSE).
