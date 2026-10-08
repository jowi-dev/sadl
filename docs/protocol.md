# sadl protocol v0

The contract between the `sadl` client and the `sadld` server (ADR-0001).
Every message in this document has a golden fixture in `protocol/fixtures/`,
and both test suites decode and re-encode every fixture losslessly. A change
here updates the fixtures and both sides' types in the same change.

## Transport

- Unix domain socket at `$XDG_RUNTIME_DIR/sadl/sadld.sock`.
- Newline-delimited JSON: one UTF-8 JSON object per line, terminated by
  `\n`. Encoders must not emit raw newlines inside a message (JSON string
  escaping already guarantees this).
- Messages are JSON-RPC 2.0 shaped. Every message carries
  `"jsonrpc": "2.0"`. Batches are not supported.

## Message kinds

**Request** (client → server). `id` is a non-negative integer, unique per
connection; the client assigns it (a counter is enough). `params` is always
an object, `{}` when the method takes none.

```json
{"jsonrpc": "2.0", "id": 1, "method": "session.open", "params": {"cwd": "/home/u/proj"}}
```

**Response** (server → client). Exactly one per request, with the request's
`id`, carrying either `result` or `error`. `id` is `null` only when the
server could not read the request's id (parse error, invalid request).

```json
{"jsonrpc": "2.0", "id": 1, "result": {"turn_id": "t_1"}}
{"jsonrpc": "2.0", "id": 1, "error": {"code": -32002, "message": "session not found"}}
```

`error.data` is optional and its shape depends on `code`.

**Notification** (server → client). No `id`, never answered. All v0
notifications are session events and carry `session_id`.

```json
{"jsonrpc": "2.0", "method": "turn.delta", "params": {"session_id": "s_1", "turn_id": "t_1", "text": "Hi"}}
```

Receivers ignore unknown object fields. Optional fields are omitted when
absent rather than sent as `null`.

## Handshake

The first request on a connection must be `handshake`. The server answers
with its own version if it supports the client's, or with error `-32000`
listing the versions it does support. Any other request before a successful
handshake gets error `-32001`.

| Method      | Params                       | Result                       |
|-------------|------------------------------|------------------------------|
| `handshake` | `{protocol_version: int}`    | `{protocol_version: int}`    |

This document defines `protocol_version` **0**.

## Requests

Session ids, turn ids and tool call ids are opaque strings minted by the
server.

A `SessionInfo` object is `{id, cwd, model, updated_at}`: all strings,
`updated_at` in RFC 3339 UTC.

| Method           | Params                          | Result                         |
|------------------|---------------------------------|--------------------------------|
| `session.open`   | `{cwd: string, model?: string}` | `SessionInfo`                  |
| `session.resume` | `{id: string}`                  | `SessionInfo`                  |
| `session.send`   | `{id: string, text: string}`    | `{turn_id: string}`            |
| `session.cancel` | `{id: string}`                  | `{}`                           |
| `session.permit` | `{id, call_id, decision}`       | `{}`                           |
| `session.list`   | `{}`                            | `{sessions: [SessionInfo]}`    |

- `session.open` starts a new session whose tools run in `cwd` (absolute
  path). Without `model`, the server uses its configured default; the result
  names the model actually used.
- `session.open` and `session.resume` subscribe the connection to that
  session's notifications. Several connections may subscribe to one session;
  each receives every notification.
- `session.send` starts a turn with the user's `text`. The response is sent
  before any notification for that turn, so the client always knows the
  `turn_id` first. Sending while a turn is running fails with `-32003`.
- `session.cancel` asks the running turn to stop and returns immediately. The
  turn then ends with `turn.end` and `stop_reason: "cancelled"`. Cancelling
  a session with no running turn succeeds and does nothing.
- `session.list` returns every persisted session, most recently updated
  first.
- `session.permit` answers the `permission.request` for tool call `call_id`
  in session `id`. `decision` is `"allow"` (the tool runs) or `"deny"` (it
  fails without running). Answering a call that is not waiting, including
  one another client already answered, fails with `-32004`.

## Notifications

Every notification below carries `session_id` and, except `error`,
`turn_id`.

| Method               | Params                                                                   |
|----------------------|--------------------------------------------------------------------------|
| `turn.delta`         | `{session_id, turn_id, text: string}`                                    |
| `tool.call`          | `{session_id, turn_id, call_id: string, name: string, args: object}`     |
| `permission.request` | `{session_id, turn_id, call_id: string}`                                 |
| `tool.result`        | `{session_id, turn_id, call_id: string, output: string, is_error: bool}` |
| `turn.end`           | `{session_id, turn_id, stop_reason: string, usage: Usage}`               |
| `error`              | `{session_id, code: int, message: string}`                               |

- `turn.delta` is the next chunk of assistant text. Concatenating a turn's
  deltas yields its full text.
- `tool.call` is sent when the model calls a tool, before it runs. `args` is
  the tool's argument object, passed through untouched.
- `permission.request` follows a `tool.call` that the session's permission
  policy (ADR-0003) says to ask about. The tool waits until a client answers
  with `session.permit`, or the turn is cancelled; there is no timeout. A
  call the policy denies gets no `permission.request`, only an error
  `tool.result`. Clients should treat the request as settled once the
  call's `tool.result` or the turn's `turn.end` arrives, since another
  client may have answered it.
- `tool.result` follows its `tool.call` (matched by `call_id`). A tool that
  failed reports `is_error: true` with the failure in `output`; that is not a
  protocol error.
- `turn.end` is the last notification of every turn. `stop_reason` is one of
  `"completed"`, `"cancelled"`, `"error"`. `Usage` is
  `{input_tokens: int, output_tokens: int}`, the turn's totals (zero if the
  provider reported none).
- `error` reports a failure that has no request to answer, such as a
  provider failure mid-turn. A turn that fails sends `error` and then
  `turn.end` with `stop_reason: "error"`.

## Error codes

| Code     | Meaning                         | `data`                  |
|----------|---------------------------------|-------------------------|
| `-32700` | Parse error (invalid JSON)      |                         |
| `-32600` | Invalid request                 |                         |
| `-32601` | Method not found                |                         |
| `-32602` | Invalid params                  |                         |
| `-32603` | Internal error                  |                         |
| `-32000` | Unsupported protocol version    | `{supported: [int]}`    |
| `-32001` | Handshake required              |                         |
| `-32002` | Session not found               |                         |
| `-32003` | Session busy (turn in progress) |                         |
| `-32004` | No pending permission request   |                         |
| `-32010` | Provider error                  |                         |

## Fixtures

`protocol/fixtures/` holds one file per message, named
`<method>.<kind>[.<variant>].json` where `<kind>` is `request`, `response`
or `notification`. A response fixture is decoded with the result type of its
`<method>`. Both test suites fail on a fixture name they do not recognise,
so a new message cannot be added without wiring it into both.

## Not in v0

- Replaying a resumed session's transcript to the client.
- Client → server notifications.
- Replaying a pending `permission.request` to a client that attaches while
  it waits.
