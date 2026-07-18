import { randomUUID } from "node:crypto";

const DEFAULT_BASE_URL = "http://127.0.0.1:8787";
const CONTROL_HEADER = "x-loophony-control";
const CONTROL_HEADER_VALUE = "codex-app";

export type LoophonyInputKind = "instruction" | "goal_adjustment" | "unblock";

export interface LoophonyOperatorInput {
  kind: LoophonyInputKind;
  message: string;
  issueIdentifier?: string | undefined;
  resumeState?: string | undefined;
  requestId?: string | undefined;
}

export interface LoophonyReviewDecision {
  decision: "maintain" | "adjust";
  feedback: string;
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

  async refresh(): Promise<unknown> {
    return this.request("/api/v1/refresh", {
      method: "POST",
      headers: controlHeaders(),
      body: "{}",
    });
  }

  async submitInput(input: LoophonyOperatorInput): Promise<unknown> {
    const payload: Record<string, string> = {
      kind: input.kind,
      message: input.message,
      request_id: input.requestId ?? randomUUID(),
    };
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
