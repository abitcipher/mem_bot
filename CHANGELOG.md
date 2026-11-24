# Changelog

## 0.1.0

- Client for the local link of `mem-botd`: `hello` (the service's card), requests to a
  `MemBot` handler, answers (`state` and `data`), pushes with the node's `ok` / `error`,
  reconnection with backoff.
- `MemBot.Value.check/1`: no floats, at most eight levels, at most 1024 items.
- `c:MemBot.handle_request/4`: the handler may take the request's id (to recognise a request
  sent again, or to answer later); `MemBot.answer/5` answers a request after `:noreply`.
- A `hello` that arrives in the same packet as the upgrade's answer is kept (it was dropped:
  no card until the next reconnect).
