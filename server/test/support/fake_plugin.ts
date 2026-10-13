// An opencode plugin for Sadld.SidecarTest. Its tools and hooks exercise
// each direction of docs/sidecar.md.
import { z } from "zod";

export const server = async ({ client, worktree }: any) => {
  // Sessions that ran /bye, which exit at their next idle as thatch's
  // /thatch/exit does.
  const leaving = new Set<string>();

  // Like thatch's direct extraction: once a top-level session that ran
  // tools goes idle, a child session is prompted to "extract", and deleted
  // when it goes idle in turn.
  const children = new Set<string>();
  const ranTools = new Set<string>();

  return {
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
        execute: async ({ id }: any) =>
          JSON.stringify(await client.session.get({ path: { id } })),
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

    "command.execute.before": async (input: any, output: any) => {
      if (input.command !== "bye") return;
      leaving.add(input.sessionID);
      output.parts[0].text += " Say goodbye.";
    },

    "tool.execute.after": async (input: any) => {
      if (!children.has(input.sessionID)) ranTools.add(input.sessionID);
    },

    event: async ({ event }: any) => {
      if (event.type === "session.created") {
        const info = event.properties.info;
        if (info.parentID) {
          children.add(info.id);
          return;
        }
        await client.session.prompt({
          path: { id: info.id },
          body: { noReply: true, parts: [{ type: "text", text: "remember me", synthetic: true }] },
        });
      } else if (event.type === "session.idle" && leaving.delete(event.properties.sessionID)) {
        await client.tui.publish({
          body: { type: "tui.command.execute", properties: { command: "app.exit" } },
        });
      }

      if (event.type === "session.status" && event.properties.status.type === "idle") {
        const id = event.properties.sessionID;

        if (children.has(id)) {
          children.delete(id);
          await client.session.delete({ path: { id } });
        } else if (ranTools.delete(id)) {
          const child = await client.session.create({ body: { parentID: id, title: "extract" } });
          const reply = await client.session.prompt({
            path: { id: child.data.id },
            body: { parts: [{ type: "text", text: "extract" }] },
          });
          console.error(`extracted: ${reply.data.parts[0].text}`);
        }
      }
    },
  };
};
