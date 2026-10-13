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
  | "agent.speak"
  | "dtmf";

/**
 * Event types that voice_core (the media body) is allowed to ingest via
 * `POST /api/v1/calls/:id/events`. `agent.speak` is deliberately excluded: it is
 * a brain→body instruction, never a body→control event.
 */
export const INGEST_EVENT_TYPES: readonly CallEventType[] = [
  "utterance.user",
  "utterance.agent",
  "call.answered",
  "call.ended",
  "call.failed",
];

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
