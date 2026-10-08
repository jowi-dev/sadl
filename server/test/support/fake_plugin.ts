// An opencode plugin for Sadld.SidecarTest. Its tools and hooks exercise
// each direction of docs/sidecar.md.
import { z } from "zod";

export const server = async ({ client, worktree }: any) => ({
  tool: {
    echo: {
      description: "Echo text.",
      args: { text: z.string() },
      execute: async ({ text }: any, ctx: any) =>
        `${text} from ${ctx.sessionID} in ${ctx.worktree}`,
    },
    peek: {
      description: "Describe a session.",
      args: { id: z.string() },
      execute: async ({ id }: any) => JSON.stringify(await client.session.get({ path: { id } })),
    },
    boom: {
      description: "Fail.",
      args: {},
      execute: async () => {
        throw new Error("kaboom");
      },
    },
  },

  "experimental.chat.system.transform": async (_input: any, output: any) => {
    output.system.push(`plugin in ${worktree}`);
  },

  event: async ({ event }: any) => {
    if (event.type !== "session.created") return;
    await client.session.prompt({
      path: { id: event.properties.info.id },
      body: { noReply: true, parts: [{ type: "text", text: "remember me", synthetic: true }] },
    });
  },
});
