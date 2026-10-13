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
  | `command.execute.before`             | `{command, sessionID, arguments}` | `{parts}`          |
  | `tool.execute.after`                 | `{tool, sessionID, callID, args}` | `{title, output, metadata}` |

  In `chat.message`, `message` is `{id, sessionID, role: "user"}` and
  `parts` holds the user's text as one `{id, sessionID, messageID, type:
  "text", text}` part. Text parts the hook appends become messages of
  their own after the user's, `synthetic` when the part says so.

  `command.execute.before` runs when a client starts slash command
  `command` (named without its `/`) with `arguments`, before its turn.
  `parts` holds the command's expanded template as one `{type: "text",
  text}` part. The text parts the hook leaves, joined with blank lines,
  become the turn's user message.

A notification is not answered:

| Method  | Params                      |
|---------|-----------------------------|
| `event` | `{event: {type, properties}}` |

sadld sends these events:

| `type`            | `properties`                                       |
|-------------------|----------------------------------------------------|
| `session.created` | `{info: Session}`, children included                 |
| `session.status`  | `{sessionID, status: {type: "busy" \| "idle"}}`    |
| `session.idle`    | `{sessionID}`                                      |
| `session.error`   | `{sessionID, error: {name, data: {message}}}`      |
| `session.deleted` | `{info: Session}`                                  |

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
| `session.create`       | `{body: {parentID, title?}}`           | `Session`              |
| `session.delete`       | `{path: {id}}`                         | `true`                 |
| `tui.showToast`        | `{body: {message, variant, ...}}`      | `true`                 |
| `tui.executeCommand`   | `{body: {command}}`                    | `true`                 |
| `tui.publish`          | `{body: {type, properties}}`           | `true`                 |

- `Session` is `{id, title, directory, time: {created, updated}}`, plus
  `parentID` for a child session, times in Unix milliseconds. sadld keeps
  no separate creation time, so `created` is `updated`, and keeps no title,
  so `title` is empty. `session.list` gives the sessions working in the
  worktree or below it, children included, and `session.status` the
  running ones.
- `session.messages` gives each message as `info` `{id, sessionID, role}`
  and `parts`, a list of one `{type: "text", text}` part (`synthetic: true`
  for injected text). `id` is `<session id>_<position>`. Tool results and
  assistant messages without text are left out.
- `session.prompt` and `session.promptAsync` join the text parts, with a
  blank line between them, into one user message, `synthetic` if any part
  is. The session must be running. With `noReply` the message is recorded
  without starting a turn, even while one runs, and `session.prompt`
  answers with it, its `info` having no `id`. Without `noReply` a turn
  starts, which fails with `-32003` at once while one is running.
  `session.promptAsync` answers as soon as the turn starts.
  `session.prompt` waits for the turn to end and answers with its final
  assistant message, `info` `{id, sessionID, role: "assistant"}` (the `id`
  of `session.messages`) and a text part; a turn that fails or is
  cancelled answers `-32603` instead.
- Because a busy session refuses a turn at once, a hook that prompts the
  session whose turn is waiting on that hook gets `-32003` back rather than
  a deadlock. A hook may wait on another session's turn.
- `session.create` starts a child of the running session `parentID`, which
  answers `-32002` if that is not running. The child inherits the parent's
  cwd, model, provider, tools, permission policy, system prompt and
  plugins, and its plugins hear `session.created` before the answer. The
  `title` is ignored. Its tool calls that the policy would ask about are
  denied, since no client watches a child, and it is not offered the
  `task` tool. Children are left out of the client protocol's
  `session.list`.
- `session.delete` deletes a session and its children, stored or running.
  A running one's turn is killed, without `session.idle`, and its plugins
  hear `session.deleted`. An unknown session answers `-32002`.
- `tui.showToast` writes the message to sadld's log.
- `tui.executeCommand` and `tui.publish` name no session: in opencode
  they act on the session its TUI shows. Here they act on the session
  sadld last told the host about, the latest named by an `event`, a `hook`
  `input` or a `tool.execute` `context`, and fail with `-32002` before
  there is one. `tui.executeCommand` takes a `command`, as does
  `tui.publish` with `type` `"tui.command.execute"` in `properties`.
  `session_compact` (or `session.compact`) compacts the session as the
  client request `session.compact` does, failing with `-32003` while a
  turn runs. `app_exit` (or `app.exit`) sends the session's clients
  `app.exit` (`docs/protocol.md`), which closes the TUI; the session
  keeps running. Any other command, or any other `tui.publish` type,
  fails with `-32602`.

Any other method answers `-32601`, the rest of `tui` included.

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
