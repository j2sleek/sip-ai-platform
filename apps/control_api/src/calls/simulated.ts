/**
 * Simulated call backend.
 *
 * Models a live call entirely in memory so the full control plane + MCP/server
 * loop can be demonstrated and tested without Asterisk. It emits a realistic
 * event sequence and produces canned user utterances so `wait_for_input`
 * (long-poll) has something to return.
 *
 * This backend is explicitly a development/demo facility; it is not telephony.
 */

import { randomUUID } from "node:crypto";

import type { BackendDeps, CallBackend, OriginatedCall } from "./backend.js";
import type { OriginateRequest } from "./types.js";

const DEFAULT_GREETING = "Hi, this is your voice assistant. How can I help?";
const CANNED_USER_REPLIES = [
  "Yes, that sounds good.",
  "Can you tell me more about that?",
  "Please go ahead and do it.",
];

export class SimulatedBackend implements CallBackend {
  readonly name = "simulated";
  private readonly registry: BackendDeps["registry"];
  private readonly log: BackendDeps["log"];
  private readonly timers = new Map<string, NodeJS.Timeout[]>();
  private readonly replyIndex = new Map<string, number>();

  constructor(deps: BackendDeps) {
    this.registry = deps.registry;
    this.log = deps.log;
  }

  async originate(request: OriginateRequest): Promise<OriginatedCall> {
    const id = randomUUID();
    this.registry.create({
      id,
      to: request.to,
      from: request.from ?? "voice_core",
      backend: this.name,
      meta: { simulated: true },
    });

    this.registry.append(id, "call.created", { to: request.to });
    this.registry.setState(id, "ringing");
    this.registry.append(id, "call.ringing", {});

    this.schedule(id, 50, () => {
      this.registry.setState(id, "answered");
      this.registry.append(id, "call.answered", {});
      this.speakInternal(id, request.greeting ?? DEFAULT_GREETING);
    });

    return { id, meta: { simulated: true } };
  }

  async speak(id: string, text: string): Promise<void> {
    if (!this.registry.get(id)) {
      throw new Error(`unknown call: ${id}`);
    }
    this.speakInternal(id, text);
  }

  private speakInternal(id: string, text: string): void {
    this.registry.setState(id, "active");
    this.registry.append(id, "utterance.agent", { text });
    // A caller "responds" shortly after the agent speaks.
    this.schedule(id, 400, () => {
      const call = this.registry.get(id);
      if (!call || call.state === "ended") return;
      const index = this.replyIndex.get(id) ?? 0;
      const reply = CANNED_USER_REPLIES[index % CANNED_USER_REPLIES.length]!;
      this.replyIndex.set(id, index + 1);
      this.registry.append(id, "utterance.user", { text: reply });
    });
  }

  async hangup(id: string): Promise<void> {
    const call = this.registry.get(id);
    if (!call) {
      throw new Error(`unknown call: ${id}`);
    }
    this.dispose(id);
    this.registry.append(id, "call.ended", { reason: "hangup" });
    this.registry.setState(id, "ended");
  }

  dispose(id: string): void {
    for (const timer of this.timers.get(id) ?? []) clearTimeout(timer);
    this.timers.delete(id);
  }

  private schedule(id: string, delayMs: number, fn: () => void): void {
    const timer = setTimeout(() => fn(), delayMs);
    timer.unref?.();
    const list = this.timers.get(id) ?? [];
    list.push(timer);
    this.timers.set(id, list);
  }
}
