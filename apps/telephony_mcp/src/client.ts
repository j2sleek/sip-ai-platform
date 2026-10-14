/**
 * HTTP client for the control_api call surface.
 *
 * Every request is bounded by a timeout and failures are surfaced as typed
 * `ControlApiError`s with a stable `code` so the MCP tools can return useful
 * messages instead of leaking stack traces.
 */

import type { TelephonyConfig } from "./config.js";

export type CallState =
  | "queued"
  | "ringing"
  | "answered"
  | "active"
  | "ended"
  | "failed";

export interface CallEvent {
  seq: number;
  at: string;
  type: string;
  data: Record<string, unknown>;
}

export interface CallSummary {
  id: string;
  to: string;
  from: string;
  /** Who initiated the call: `outbound` (originated here) or `inbound` (dialled in). */
  direction: "inbound" | "outbound";
  state: CallState;
  backend: string;
  createdAt: string;
  endedAt: string | null;
}

export interface TranscriptTurn {
  role: "user" | "agent";
  text: string;
  at: string;
}

export interface CallDetail extends CallSummary {
  events: CallEvent[];
  transcript: TranscriptTurn[];
}

export interface WaitResult {
  utterance: string | null;
  cursor: number;
  timedOut: boolean;
  callEnded: boolean;
}

export class ControlApiError extends Error {
  constructor(
    message: string,
    readonly code: string = "control_api_error",
    readonly status?: number,
  ) {
    super(message);
    this.name = "ControlApiError";
  }
}

export class ControlApiClient {
  private readonly baseUrl: string;
  private readonly token: string;
  private readonly timeoutMs: number;

  constructor(config: TelephonyConfig) {
    this.baseUrl = config.controlApiUrl;
    this.token = config.controlToken;
    this.timeoutMs = config.requestTimeoutMs;
  }

  private async request<T>(method: string, path: string): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    const headers: Record<string, string> = { Accept: "application/json" };
    if (this.token !== "") headers.Authorization = `Bearer ${this.token}`;

    try {
      const response = await fetch(this.baseUrl + path, {
        method,
        headers,
        signal: controller.signal,
      });

      const text = await response.text();
      const body = text ? JSON.parse(text) : {};

      if (!response.ok) {
        const message =
          (body as { error?: { message?: string } }).error?.message ??
          `HTTP ${response.status}`;
        throw new ControlApiError(message, "control_api_http_error", response.status);
      }
      return body as T;
    } catch (err) {
      if (err instanceof ControlApiError) throw err;
      if (err instanceof Error && err.name === "AbortError") {
        throw new ControlApiError(
          `control_api ${method} ${path} timed out`,
          "control_api_timeout",
        );
      }
      throw new ControlApiError(
        `control_api ${method} ${path} failed: ${(err as Error).message}`,
        "control_api_transport_error",
      );
    } finally {
      clearTimeout(timer);
    }
  }

  private async post<T>(path: string, payload: unknown): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    const headers: Record<string, string> = {
      Accept: "application/json",
      "Content-Type": "application/json",
    };
    if (this.token !== "") headers.Authorization = `Bearer ${this.token}`;

    try {
      const response = await fetch(this.baseUrl + path, {
        method: "POST",
        headers,
        body: JSON.stringify(payload ?? {}),
        signal: controller.signal,
      });
      const text = await response.text();
      const body = text ? JSON.parse(text) : {};
      if (!response.ok) {
        const message =
          (body as { error?: { message?: string } }).error?.message ??
          `HTTP ${response.status}`;
        throw new ControlApiError(message, "control_api_http_error", response.status);
      }
      return body as T;
    } catch (err) {
      if (err instanceof ControlApiError) throw err;
      if (err instanceof Error && err.name === "AbortError") {
        throw new ControlApiError(
          `control_api POST ${path} timed out`,
          "control_api_timeout",
        );
      }
      throw new ControlApiError(
        `control_api POST ${path} failed: ${(err as Error).message}`,
        "control_api_transport_error",
      );
    } finally {
      clearTimeout(timer);
    }
  }

  async originateCall(request: {
    to: string;
    from?: string;
    greeting?: string;
  }): Promise<CallSummary> {
    const body = await this.post<{ call: CallSummary }>("/api/v1/calls", request);
    return body.call;
  }

  async listCalls(): Promise<CallSummary[]> {
    const body = await this.request<{ calls: CallSummary[] }>("GET", "/api/v1/calls");
    return body.calls;
  }

  async getCall(id: string): Promise<CallDetail> {
    const body = await this.request<{ call: Omit<CallDetail, "transcript"> }>(
      "GET",
      `/api/v1/calls/${encodeURIComponent(id)}`,
    );
    return { ...body.call, transcript: toTranscript(body.call.events ?? []) };
  }

  async speak(id: string, text: string): Promise<CallSummary> {
    const body = await this.post<{ call: CallSummary }>(
      `/api/v1/calls/${encodeURIComponent(id)}/speak`,
      { text },
    );
    return body.call;
  }

  async hangup(id: string): Promise<CallSummary> {
    const body = await this.post<{ call: CallSummary }>(
      `/api/v1/calls/${encodeURIComponent(id)}/hangup`,
      {},
    );
    return body.call;
  }

  async transcript(id: string): Promise<TranscriptTurn[]> {
    const call = await this.getCall(id);
    return toTranscript(call.events);
  }

  /**
   * Long-polls the event stream until the next caller (`user`) utterance after
   * `afterSeq`, the call ends, or the timeout elapses.
   */
  async waitForInput(id: string, afterSeq: number, timeoutMs: number): Promise<WaitResult> {
    let cursor = afterSeq;
    const deadline = Date.now() + timeoutMs;

    while (Date.now() < deadline) {
      const remaining = Math.max(1, deadline - Date.now());
      const body = await this.request<{
        events: CallEvent[];
        call: CallSummary;
        cursor: number;
      }>(
        "GET",
        `/api/v1/calls/${encodeURIComponent(id)}/events?since=${cursor}&wait=${remaining}`,
      );

      const utterance = body.events.find((event) => event.type === "utterance.user");
      if (utterance) {
        return {
          utterance: String(utterance.data.text ?? ""),
          cursor: utterance.seq,
          timedOut: false,
          callEnded: false,
        };
      }

      cursor = body.cursor;

      if (body.call.state === "ended" || body.call.state === "failed") {
        return { utterance: null, cursor, timedOut: false, callEnded: true };
      }
    }

    return { utterance: null, cursor, timedOut: true, callEnded: false };
  }
}

export function toTranscript(events: CallEvent[]): TranscriptTurn[] {
  const turns: TranscriptTurn[] = [];
  for (const event of events) {
    if (event.type === "utterance.user") {
      turns.push({ role: "user", text: String(event.data.text ?? ""), at: event.at });
    } else if (event.type === "utterance.agent") {
      turns.push({ role: "agent", text: String(event.data.text ?? ""), at: event.at });
    }
  }
  return turns;
}
