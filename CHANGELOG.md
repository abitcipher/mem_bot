# Changelog

## 0.1.0

- Client for the local link of `mem-botd`: `hello` (the service's card), requests to a
  `MemBot` handler, answers (`state` and `data`), pushes with the node's `ok` / `error`,
  reconnection with backoff.
- `MemBot.Value.check/1`: no floats, at most eight levels, at most 1024 items.
