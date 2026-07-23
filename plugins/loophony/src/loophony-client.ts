import { randomUUID } from "node:crypto";

const DEFAULT_BASE_URL = "http://127.0.0.1:8787";
const CONTROL_HEADER = "x-loophony-control";
const CONTROL_HEADER_VALUE = "codex-app";

export type LoophonyInputKind = "instruction" | "goal_adjustment" | "preempt" | "unblock";

export interface LoophonyOperatorInput {
  kind: LoophonyInputKind;
  message: string;
  title?: string | undefined;
  priority?: 0 | 1 | 2 | 3 | 4 | undefined;
  issueIdentifier?: string | undefined;
  resumeState?: string | undefined;
  requestId?: string | undefined;
}

export interface LoophonyReviewDecision {
  decision: "maintain" | "adjust";
  feedback: string;
}

export interface LoophonyMemorySearch {
  query: string;
  issueIdentifier?: string | undefined;
  sessionId?: string | undefined;
  sourceTypes?:
    | Array<
        | "linear_project"
        | "linear_issue"
        | "session_summary"
        | "checkpoint"
        | "agent_final"
        | "error"
        | "session_event"
      >
    | undefined;
  from?: string | undefined;
  to?: string | undefined;
  limit?: number | undefined;
}

export interface LoophonyAuditQuery {
  resourceType?: string | undefined;
  resourceId?: string | undefined;
  action?: string | undefined;
  outcome?: string | undefined;
  limit?: number | undefined;
}

export class LoophonyClient {
  private readonly baseUrl: URL;

  constructor(
    baseUrl = process.env.LOOPHONY_BASE_URL ?? DEFAULT_BASE_URL,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {
    this.baseUrl = validateBaseUrl(baseUrl);
  }

  async getStatus(issueIdentifier?: string): Promise<unknown> {
    const path = issueIdentifier
      ? `/api/v1/${encodeURIComponent(issueIdentifier)}`
      : "/api/v1/state";
    return this.request(path, { method: "GET" });
  }

  async getMemoryStatus(): Promise<unknown> {
    return this.request("/api/v1/memory/status", { method: "GET" });
  }

  async searchMemory(input: LoophonyMemorySearch): Promise<unknown> {
    const payload: Record<string, unknown> = { query: input.query };
    if (input.issueIdentifier) payload.issue_identifier = input.issueIdentifier;
    if (input.sessionId) payload.session_id = input.sessionId;
    if (input.sourceTypes) payload.source_types = input.sourceTypes;
    if (input.from) payload.from = input.from;
    if (input.to) payload.to = input.to;
    if (input.limit) payload.limit = input.limit;

    return this.request("/api/v1/memory/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
  }

  async getMemorySession(sessionId: string): Promise<unknown> {
    return this.request(`/api/v1/memory/sessions/${encodeURIComponent(sessionId)}`, {
      method: "GET",
    });
  }

  async getAuditLog(input: LoophonyAuditQuery = {}): Promise<unknown> {
    const params = new URLSearchParams();
    if (input.resourceType) params.set("resource_type", input.resourceType);
    if (input.resourceId) params.set("resource_id", input.resourceId);
    if (input.action) params.set("action", input.action);
    if (input.outcome) params.set("outcome", input.outcome);
    if (input.limit) params.set("limit", String(input.limit));
    const query = params.size > 0 ? `?${params.toString()}` : "";
    return this.request(`/api/v1/audit${query}`, { method: "GET" });
  }

  async verifyAuditLog(): Promise<unknown> {
    return this.request("/api/v1/audit/verify", { method: "GET" });
  }

  async getJobs(issueId?: string, status?: string): Promise<unknown> {
    const params = new URLSearchParams();
    if (issueId) params.set("issue_id", issueId);
    if (status) params.set("status", status);
    const query = params.size > 0 ? `?${params.toString()}` : "";
    return this.request(`/api/v1/jobs${query}`, { method: "GET" });
  }

  async stopJob(jobId: string): Promise<unknown> {
    return this.request(`/api/v1/jobs/${encodeURIComponent(jobId)}/stop`, {
      method: "POST",
      headers: controlHeaders(),
      body: "{}",
    });
  }

  async getWaits(): Promise<unknown> {
    return this.request("/api/v1/waits", { method: "GET" });
  }

  async refresh(): Promise<unknown> {
    return this.request("/api/v1/refresh", {
      method: "POST",
      headers: controlHeaders(),
      body: "{}",
    });
  }

  async submitInput(input: LoophonyOperatorInput): Promise<unknown> {
    const payload: Record<string, unknown> = {
      kind: input.kind,
      message: input.message,
      request_id: input.requestId ?? randomUUID(),
    };
    if (input.title) payload.title = input.title;
    if (input.priority !== undefined) payload.priority = input.priority;
    if (input.issueIdentifier) payload.issue_identifier = input.issueIdentifier;
    if (input.resumeState) payload.resume_state = input.resumeState;

    return this.request("/api/v1/operator-input", {
      method: "POST",
      headers: controlHeaders(),
      body: JSON.stringify(payload),
    });
  }

  async submitReviewDecision(input: LoophonyReviewDecision): Promise<unknown> {
    return this.request("/api/v1/review-decision", {
      method: "POST",
      headers: controlHeaders(),
      body: JSON.stringify(input),
    });
  }

  private async request(path: string, init: RequestInit): Promise<unknown> {
    const url = new URL(path, this.baseUrl);
    let response: Response;

    try {
      response = await this.fetchImpl(url, init);
    } catch (error) {
      throw new Error(
        `Loophony daemon is unavailable at ${this.baseUrl.origin}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }

    const body = await readJson(response);
    if (!response.ok) {
      const message =
        extractErrorMessage(body) ?? `Loophony request failed with HTTP ${response.status}`;
      throw new Error(message);
    }
    return body;
  }
}

function validateBaseUrl(value: string): URL {
  const url = new URL(value);
  const loopbackHosts = new Set(["127.0.0.1", "localhost", "[::1]"]);
  if (url.protocol !== "http:" || !loopbackHosts.has(url.hostname)) {
    throw new Error("LOOPHONY_BASE_URL must use HTTP on localhost or a loopback address");
  }
  url.pathname = "/";
  url.search = "";
  url.hash = "";
  return url;
}

function controlHeaders(): HeadersInit {
  return {
    "content-type": "application/json",
    [CONTROL_HEADER]: CONTROL_HEADER_VALUE,
  };
}

async function readJson(response: Response): Promise<unknown> {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return text;
  }
}

function extractErrorMessage(body: unknown): string | undefined {
  if (!body || typeof body !== "object" || Array.isArray(body)) return undefined;
  const error = (body as { error?: unknown }).error;
  if (!error || typeof error !== "object" || Array.isArray(error)) return undefined;
  const message = (error as { message?: unknown }).message;
  return typeof message === "string" ? message : undefined;
}
