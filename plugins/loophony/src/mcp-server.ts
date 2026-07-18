import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

import { LoophonyClient } from "./loophony-client.js";

const server = new McpServer({ name: "loophony", version: "0.1.0" });
let runtime: LoophonyClient | undefined;
const loophony = () => (runtime ??= new LoophonyClient());
const result = (value: unknown) => ({
  content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }],
});

server.registerTool(
  "loophony_status",
  {
    description:
      "Read the local Loophony daemon report, including running, queued, retrying, blocked, review-gate, heartbeat, token, and durable-loop state.",
    inputSchema: { issueIdentifier: z.string().min(1).optional() },
    annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
  },
  async ({ issueIdentifier }) => result(await loophony().getStatus(issueIdentifier)),
);

server.registerTool(
  "loophony_refresh",
  {
    description: "Ask the local Loophony daemon to poll and reconcile its Linear project now.",
    inputSchema: {},
    annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false },
  },
  async () => result(await loophony().refresh()),
);

server.registerTool(
  "loophony_submit_operator_input",
  {
    description:
      "Persist an explicit human instruction, goal adjustment, or unblock decision to the managed Linear issue for Loophony to consume at a safe checkpoint.",
    inputSchema: {
      kind: z.enum(["instruction", "goal_adjustment", "unblock"]),
      message: z.string().min(1).max(10_000),
      issueIdentifier: z.string().min(1).optional(),
      resumeState: z.string().min(1).max(120).optional(),
      requestId: z.string().min(1).max(128).optional(),
    },
    annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false },
  },
  async (input) => result(await loophony().submitInput(input)),
);

server.registerTool(
  "loophony_submit_review_decision",
  {
    description:
      "Resolve an open Loophony scheduled goal-review gate with an explicit maintain or adjust decision and required human feedback.",
    inputSchema: {
      decision: z.enum(["maintain", "adjust"]),
      feedback: z.string().min(1).max(10_000),
    },
    annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false },
  },
  async (input) => result(await loophony().submitReviewDecision(input)),
);

await server.connect(new StdioServerTransport());
