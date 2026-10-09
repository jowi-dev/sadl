# sadl plugin sidecar protocol

The contract between `sadld` and the plugin host it runs in Bun,
`server/priv/sidecar/plugin_host.ts` (ADR-0004). The host loads one opencode
plugin for one worktree. Every message here has a golden fixture in
`protocol/sidecar/fixtures/`, which the server's test suite decodes and
re-encodes losslessly.

## Transport

- The host's stdin and stdout. sadld starts it as
  `bun plugin_host.ts` in the worktree.
- Newline-delimited JSON, one object per line, JSON-RPC 2.0 shaped with
  `"jsonrpc": "2.0"`, as in `docs/protocol.md`.
- Both sides send requests. Each side numbers its own requests from 0, so
  an `id` names a request only together with its direction.
- The host writes log text to stderr, which sadld logs.
- The host stops on SIGTERM or when its stdin closes, after calling the
  plugin's `dispose` hook.

Objects pass through in opencode's shapes, camelCase keys included
(`sessionID`, `noReply`). Receivers ignore fields they do not know.

## sadld → host

The host answers requests in any order, but handles none before `init`
has answered.

| Method         | Params                              | Result                 |
|----------------|-------------------------------------|------------------------|
| `init`         | `{plugin, worktree}`                | `{tools: [ToolSpec]}`  |
| `tool.execute` | `{tool, args, context}`             | `{output: string}`     |
| `hook`         | `{name, input, output}`             | `{output}`             |

- `init` imports the module at the path `plugin` and calls its `server`
  export with `worktree`. `ToolSpec` is `{name, description, parameters}`,
  `parameters` being the JSON Schema of the tool's argument object.
- `tool.execute` validates `args` against the tool's schema and runs it.
  `context` is `{sessionID, messageID, callID, agent, directory,
  worktree}`. A tool that throws or rejects its arguments answers error
  `-32020` with the failure as `message`.
- `hook` calls the plugin hook `name` with `input` and `output` and
  answers with `output` as the hook left it. A plugin without that hook
  answers `output` unchanged. sadld calls:

  | Hook                                 | `input`                         | `output`             |
  |--------------------------------------|---------------------------------|----------------------|
  | `experimental.chat.system.transform` | `{sessionID, model: {id}}`      | `{system: [string]}` |
  | `chat.message`                       | `{sessionID, messageID}`        | `{message, parts}`   |
  | `tool.execute.after`                 | `{tool, sessionID, callID, args}` | `{title, output, metadata}` |

  In `chat.message`, `message` is `{id, sessionID, role: "user"}` and
  `parts` holds the user's text as one `{id, sessionID, messageID, type:
  "text", text}` part. Text parts the hook appends become messages of
  their own after the user's, `synthetic` when the part says so.

A notification is not answered:

| Method  | Params                      |
|---------|-----------------------------|
| `event` | `{event: {type, properties}}` |

sadld sends these events:

| `type`            | `properties`                                       |
|-------------------|----------------------------------------------------|
| `session.created` | `{info: Session}`                                  |
| `session.status`  | `{sessionID, status: {type: "busy" \| "idle"}}`    |
| `session.idle`    | `{sessionID}`                                      |
| `session.error`   | `{sessionID, error: {name, data: {message}}}`      |

## host → sadld

The plugin's `client` turns each SDK call `client.<group>.<name>(options)`
into a request with method `<group>.<name>` and the options object as
params. The result is the call's `data`; the host hands the plugin
`{data}`, or `{error}` for an error response, as opencode's SDK does.

| Method                 | Params                                 | Result                 |
|------------------------|----------------------------------------|------------------------|
| `session.get`          | `{path: {id}}`                         | `Session`              |
| `session.list`         | `{}`                                   | `[Session]`            |
| `session.status`       | `{}`                                   | `{<id>: {type}}`       |
| `session.messages`     | `{path: {id}}`                         | `[{info, parts}]`      |
| `session.prompt`       | `{path: {id}, body: {parts, noReply?}}`| `{info, parts}`        |
| `session.promptAsync`  | `{path: {id}, body: {parts, noReply?}}`| `{}`                   |
| `tui.showToast`        | `{body: {message, variant, ...}}`      | `true`                 |

- `Session` is `{id, title, directory, time: {created, updated}}`, times in
  Unix milliseconds; sadld keeps no separate creation time, so `created` is
  `updated`. `session.list` gives the sessions working in the worktree or
  below it, `session.status` the running ones.
- `session.messages` gives each message as `info` `{id, sessionID, role}`
  and `parts`, a list of one `{type: "text", text}` part (`synthetic: true`
  for injected text). `id` is `<session id>_<position>`. Tool results and
  assistant messages without text are left out.
- `session.prompt` and `session.promptAsync` join the text parts, with a
  blank line between them, into one user message, `synthetic` if any part
  is. With `noReply` it is recorded without starting a turn, even while one
  runs. Without it a turn starts, which fails with `-32003` while one is
  running. Neither waits for the turn: `session.prompt` answers with the
  recorded message, whose `info` has no `id`. The session must be running.
- `tui.showToast` writes the message to sadld's log.

Any other method answers `-32601`. That includes `session.create`,
`session.delete` and the rest of `tui`.

## Error codes

| Code     | Meaning                         |
|----------|---------------------------------|
| `-32601` | Method not found                |
| `-32602` | Invalid params                  |
| `-32603` | Internal error                  |
| `-32002` | Session not found               |
| `-32003` | Session busy (turn in progress) |
| `-32020` | Tool failed                     |
| `-32021` | Plugin failed to load           |

## Fixtures

`protocol/sidecar/fixtures/` follows the naming of `protocol/fixtures/`:
`<method>.<kind>[.<variant>].json`, `<kind>` being `request`, `response`
or `notification`.
