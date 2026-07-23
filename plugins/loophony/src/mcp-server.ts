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
      "Read the local Loophony daemon report, including running, queued, Waiting, durable jobs, retries, Blocked work, goal/review policy, memory/audit health, budgets, heartbeat, tokens, and loop state.",
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
  "loophony_memory_status",
  {
    description:
      "Check whether Loophony's Onyx v4 and OpenSearch 3.6 cross-session memory are available.",
    inputSchema: {},
    annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
  },
  async () => result(await loophony().getMemoryStatus()),
);

server.registerTool(
  "loophony_search_memory",
  {
    description:
      "Hybrid-search the canonical Linear project objective, current issue snapshots, session summaries, and raw Loophony loop evidence through Onyx v4 and OpenSearch 3.6 without invoking a generative LLM.",
    inputSchema: {
      query: z.string().min(1).max(10_000),
      issueIdentifier: z.string().min(1).optional(),
      sessionId: z.string().min(1).optional(),
      sourceTypes: z
        .array(
          z.enum([
            "linear_project",
            "linear_issue",
            "session_summary",
            "checkpoint",
            "agent_final",
            "error",
            "session_event",
          ]),
        )
        .max(7)
        .optional(),
      from: z.string().min(1).optional(),
      to: z.string().min(1).optional(),
      limit: z.number().int().min(1).max(100).optional(),
    },
    annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
  },
  async (input) => result(await loophony().searchMemory(input)),
);

server.registerTool(
  "loophony_get_memory_session",
  {
    description:
      "Read one Loophony Codex loop session's summary plus ordered raw evidence and metadata.",
    inputSchema: { sessionId: z.string().min(1) },
    annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
  },
  async ({ sessionId }) => result(await loophony().getMemorySession(sessionId)),
);

server.registerTool(
  "loophony_audit_log",
  {
    description:
      "Read Loophony's append-only, secret-redacted, versioned canonical SHA-256 hash-chained operational audit events.",
    inputSchema: {
      resourceType: z.string().min(1).optional(),
      resourceId: z.string().min(1).optional(),
      action: z.string().min(1).optional(),
      outcome: z.string().min(1).optional(),
      limit: z.number().int().min(1).max(1000).optional(),
    },
    annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
  },
  async (input) => result(await loophony().getAuditLog(input)),
);

server.registerTool(
  "loophony_verify_audit_log",
  {
    description: "Verify Loophony's durable audit-event SHA-256 hash chain from genesis to head.",
    inputSchema: {},
    annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
  },
  async () => result(await loophony().verifyAuditLog()),
);

server.registerTool(
  "loophony_list_jobs",
  {
    description: "List detached durable collector and long-running jobs owned by Loophony.",
    inputSchema: {
      issueId: z.string().min(1).optional(),
      status: z.string().min(1).optional(),
    },
    annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
  },
  async ({ issueId, status }) => result(await loophony().getJobs(issueId, status)),
);

server.registerTool(
  "loophony_list_waits",
  {
    description: "List automated wait triggers currently monitored without a Codex session.",
    inputSchema: {},
    annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
  },
  async () => result(await loophony().getWaits()),
);

server.registerTool(
  "loophony_stop_job",
  {
    description: "Request graceful termination of one Loophony-owned durable job.",
    inputSchema: { jobId: z.string().min(1) },
    annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: true },
  },
  async ({ jobId }) => result(await loophony().stopJob(jobId)),
);

server.registerTool(
  "loophony_submit_operator_input",
  {
    description:
      "Create a prioritized Human issue in Linear from explicit feedback. Loophony later claims it and creates a linked Work issue; only preempt explicitly interrupts the current Codex turn.",
    inputSchema: {
      kind: z.enum(["instruction", "goal_adjustment", "preempt", "unblock"]),
      message: z.string().min(1).max(10_000),
      title: z.string().min(1).max(200).optional(),
      priority: z.number().int().min(0).max(4).optional(),
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
