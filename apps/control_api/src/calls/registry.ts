/**
 * In-memory call registry with a per-call event log and long-poll support.
 *
 * The registry is the control_api's source of truth for call *control* state
 * (originate/progress/hangup and transcript events surfaced to MCP clients).
 * Media and agent state remain owned by voice_core; events correlate by
 * `call_id`.
 *
 * A single registry instance is created per app so tests are isolated.
 */

import { EventEmitter } from "node:events";

import type { CallEvent, CallEventType, CallRecord, CallState } from "./types.js";

interface EventEnvelope {
  callId: string;
  event: CallEvent;
}

export class CallRegistry {
  private readonly calls = new Map<string, CallRecord>();
  private readonly emitter = new EventEmitter();
  private readonly maxEvents: number;

  constructor(maxEvents: number) {
    this.maxEvents = maxEvents;
    // Many concurrent long-polls may listen at once.
    this.emitter.setMaxListeners(0);
  }

  create(record: {
    id: string;
    to: string;
    from: string;
    backend: string;
    meta?: Record<string, unknown>;
  }): CallRecord {
    const created: CallRecord = {
      id: record.id,
      to: record.to,
      from: record.from,
      state: "queued",
      backend: record.backend,
      createdAt: new Date().toISOString(),
      endedAt: null,
      events: [],
      meta: record.meta ?? {},
    };
    this.calls.set(record.id, created);
    return created;
  }

  get(id: string): CallRecord | undefined {
    return this.calls.get(id);
  }

  list(): CallRecord[] {
    return [...this.calls.values()].sort((a, b) =>
      a.createdAt < b.createdAt ? 1 : -1,
    );
  }

  /** Appends an event, trims the log, notifies waiters, and returns it. */
  append(
    id: string,
    type: CallEventType,
    data: Record<string, unknown> = {},
  ): CallEvent | undefined {
    const call = this.calls.get(id);
    if (!call) return undefined;

    const seq = call.events.length === 0 ? 1 : call.events[call.events.length - 1]!.seq + 1;
    const event: CallEvent = { seq, at: new Date().toISOString(), type, data };

    call.events.push(event);
    if (call.events.length > this.maxEvents) {
      call.events.splice(0, call.events.length - this.maxEvents);
    }

    const envelope: EventEnvelope = { callId: id, event };
    this.emitter.emit("event", envelope);
    return event;
  }

  setState(id: string, state: CallState): void {
    const call = this.calls.get(id);
    if (!call) return;
    call.state = state;
    if (state === "ended" || state === "failed") {
      call.endedAt = new Date().toISOString();
    }
  }

  mergeMeta(id: string, meta: Record<string, unknown>): void {
    const call = this.calls.get(id);
    if (!call) return;
    call.meta = { ...call.meta, ...meta };
  }

  eventsSince(id: string, sinceSeq: number): CallEvent[] {
    const call = this.calls.get(id);
    if (!call) return [];
    return call.events.filter((event) => event.seq > sinceSeq);
  }

  /**
   * Long-poll: resolves with events after `sinceSeq`, or `[]` after `waitMs`.
   * Resolves immediately when events already exist.
   */
  waitForEvents(id: string, sinceSeq: number, waitMs: number): Promise<CallEvent[]> {
    const existing = this.eventsSince(id, sinceSeq);
    if (existing.length > 0 || !this.calls.has(id)) {
      return Promise.resolve(existing);
    }

    return new Promise((resolve) => {
      const onEvent = (envelope: EventEnvelope): void => {
        if (envelope.callId !== id) return;
        cleanup();
        resolve(this.eventsSince(id, sinceSeq));
      };
      const timer = setTimeout(() => {
        cleanup();
        resolve([]);
      }, waitMs);
      const cleanup = (): void => {
        clearTimeout(timer);
        this.emitter.off("event", onEvent);
      };

      this.emitter.on("event", onEvent);
    });
  }

  remove(id: string): void {
    this.calls.delete(id);
  }
}
