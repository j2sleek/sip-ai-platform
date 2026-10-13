/**
 * Call control backend abstraction.
 *
 * A backend executes originate/speak/hangup for a call and reports progress via
 * the `CallRegistry` event log. Two implementations exist:
 *
 *  - `simulated` (default): fully in-memory, used for demos and tests with no
 *    telephony stack present.
 *  - `ari`: talks to Asterisk's ARI REST interface (real control plane).
 *
 * Media and the AI agent are owned by voice_core; the backend only drives call
 * *control* (AGENTS.md rules 1–3).
 */

import type { CallRegistry } from "./registry.js";
import type { OriginateRequest } from "./types.js";

export interface OriginatedCall {
  id: string;
  meta: Record<string, unknown>;
}

export interface CallBackend {
  readonly name: string;
  originate(request: OriginateRequest): Promise<OriginatedCall>;
  speak(id: string, text: string): Promise<void>;
  hangup(id: string): Promise<void>;
  /** Releases timers/handles held for a call. Called on hangup and on close. */
  dispose(id: string): void;
}

export interface BackendDeps {
  registry: CallRegistry;
  log: {
    info: (obj: unknown, msg?: string) => void;
    warn: (obj: unknown, msg?: string) => void;
    error: (obj: unknown, msg?: string) => void;
  };
}

export const __backendMarker = true as const;

export type { CallRegistry };
