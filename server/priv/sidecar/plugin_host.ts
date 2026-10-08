// Hosts one opencode plugin for sadld, speaking docs/sidecar.md over stdin
// and stdout. sadld starts one host per plugin and worktree (ADR-0004).

import { dirname } from "node:path";

type Json = any;
type Hooks = Record<string, any>;

// Error codes from docs/sidecar.md.
const INVALID_PARAMS = -32602;
const METHOD_NOT_FOUND = -32601;
const INTERNAL_ERROR = -32603;
const TOOL_FAILED = -32020;
const LOAD_FAILED = -32021;

class RpcError extends Error {
  constructor(readonly code: number, message: string) {
    super(message);
  }
}

// stdout carries the protocol, so anything a plugin logs goes to stderr.
const write = (message: Json) =>
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
console.log = console.info = console.debug = console.error;

// --- host -> sadld: the plugin's `client` -----------------------------------

let nextId = 0;
const waiting = new Map<number, (response: Json) => void>();

function request(method: string, params: Json): Promise<Json> {
  const id = nextId++;
  return new Promise((resolve) => {
    waiting.set(id, (response) =>
      resolve("error" in response ? { error: response.error } : { data: response.result }),
    );
    write({ id, method, params });
  });
}

// opencode's SDK client: `client.<group>.<name>(options)` resolves to
// `{data}` or `{error}`. `then` stays undefined so awaiting a group does not
// mistake it for a promise.
const group = (name: string) =>
  new Proxy(
    {},
    {
      get: (_target, method) =>
        method === "then"
          ? undefined
          : (options?: Json) => request(`${name}.${String(method)}`, options ?? {}),
    },
  );

const client = new Proxy(
  {},
  { get: (_target, name) => (name === "then" ? undefined : group(String(name))) },
);

// --- sadld -> host ----------------------------------------------------------

let hooks: Hooks | null = null;
let z: Json = null;
let loaded: Promise<void> | null = null;

async function init({ plugin, worktree }: Json): Promise<Json> {
  if (loaded) throw new RpcError(INVALID_PARAMS, "already initialised");
  let done: () => void = () => {};
  loaded = new Promise((resolve) => (done = resolve));

  try {
    const module = await import(plugin);
    // Tool arguments are zod shapes; use the plugin's own zod to read them.
    const zod = await import(Bun.resolveSync("zod", dirname(plugin)));
    z = zod.z ?? zod;
    const server = module.server ?? module.default?.server ?? module.default;
    hooks = await server({
      client,
      worktree,
      directory: worktree,
      project: { id: worktree, worktree },
      $: Bun.$,
      serverUrl: new URL("http://localhost"),
    });
  } catch (err) {
    throw new RpcError(LOAD_FAILED, String(err));
  } finally {
    done();
  }

  const tools = Object.entries<Json>(hooks!.tool ?? {}).map(([name, tool]) => ({
    name,
    description: tool.description,
    parameters: parameters(tool.args),
  }));
  return { tools };
}

function parameters(args: Json): Json {
  const { $schema: _, ...schema } = z.toJSONSchema(z.object(args ?? {}));
  return schema;
}

async function loadedHooks(): Promise<Hooks> {
  if (loaded) await loaded;
  if (!hooks) throw new RpcError(LOAD_FAILED, "plugin not loaded");
  return hooks;
}

async function executeTool({ tool: name, args, context }: Json): Promise<Json> {
  const tool = (await loadedHooks()).tool?.[name];
  if (!tool) throw new RpcError(TOOL_FAILED, `unknown tool ${JSON.stringify(name)}`);

  const parsed = z.object(tool.args ?? {}).safeParse(args ?? {});
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i: Json) =>
      i.path.length ? `${i.path.join(".")}: ${i.message}` : i.message,
    );
    throw new RpcError(TOOL_FAILED, issues.join("; "));
  }

  try {
    const result = await tool.execute(parsed.data, {
      ...context,
      abort: new AbortController().signal,
      metadata: () => {},
      ask: async () => {},
    });
    return { output: typeof result === "string" ? result : String(result?.output ?? "") };
  } catch (err) {
    throw new RpcError(TOOL_FAILED, err instanceof Error ? err.message : String(err));
  }
}

async function runHook({ name, input, output }: Json): Promise<Json> {
  const hook = (await loadedHooks())[name];
  if (typeof hook === "function") await hook(input, output);
  return { output };
}

const methods: Record<string, (params: Json) => Promise<Json>> = {
  init,
  "tool.execute": executeTool,
  hook: runHook,
};

async function answer(id: number, method: string, params: Json) {
  const handler = methods[method];
  try {
    if (!handler) throw new RpcError(METHOD_NOT_FOUND, "method not found");
    write({ id, result: await handler(params) });
  } catch (err) {
    const code = err instanceof RpcError ? err.code : INTERNAL_ERROR;
    write({ id, error: { code, message: err instanceof Error ? err.message : String(err) } });
  }
}

async function notify(method: string, params: Json) {
  if (method !== "event") return;
  try {
    await (await loadedHooks()).event?.({ event: params.event });
  } catch (err) {
    console.error(`[plugin_host] event ${params.event?.type} failed: ${err}`);
  }
}

function dispatch(line: string) {
  let message: Json;
  try {
    message = JSON.parse(line);
  } catch {
    console.error(`[plugin_host] unreadable line: ${line}`);
    return;
  }

  if ("method" in message) {
    if ("id" in message) void answer(message.id, message.method, message.params ?? {});
    else void notify(message.method, message.params ?? {});
  } else {
    waiting.get(message.id)?.(message);
    waiting.delete(message.id);
  }
}

let stopping = false;

async function stop() {
  if (stopping) return;
  stopping = true;
  try {
    // Lets the plugin release native resources before Bun tears down.
    await hooks?.dispose?.();
  } catch (err) {
    console.error(`[plugin_host] dispose failed: ${err}`);
  }
  process.exit(0);
}

process.on("SIGTERM", stop);
process.on("SIGINT", stop);

for await (const line of console) {
  if (line.trim() !== "") dispatch(line);
}
await stop();
