/**
 * Call control types shared across the calls module.
 */

export type CallState =
  | "queued"
  | "ringing"
  | "answered"
  | "active"
  | "ended"
  | "failed";

export type CallEventType =
  | "call.created"
  | "call.ringing"
  | "call.answered"
  | "call.ended"
  | "call.failed"
  | "utterance.user"
  | "utterance.agent"
  | "dtmf";

export interface CallEvent {
  /** Monotonic per-call sequence number, starting at 1. */
  seq: number;
  /** ISO-8601 timestamp. */
  at: string;
  type: CallEventType;
  data: Record<string, unknown>;
}

export interface CallRecord {
  id: string;
  /** Destination (SIP URI, extension, or E.164 number). */
  to: string;
  /** Caller identity presented to the callee. */
  from: string;
  state: CallState;
  /** Name of the backend that owns this call. */
  backend: string;
  createdAt: string;
  endedAt: string | null;
  /** Bounded event log (oldest trimmed first). */
  events: CallEvent[];
  /** Backend-specific metadata (e.g. ARI channel id). Never contains secrets. */
  meta: Record<string, unknown>;
}

export interface OriginateRequest {
  to: string;
  from?: string;
  /** Optional first thing the agent says when the call is answered. */
  greeting?: string;
}
