/**
 * Call service: owns the registry + backend for the lifetime of the app and
 * exposes the call routes. One instance per Fastify app (isolates tests).
 *
 * A Fastify instance is augmented with `.calls` (see the module augmentation
 * below) so tests and other routes can reach the registry.
 */

import type { FastifyInstance } from "fastify";

import type { Config } from "../config.js";
import { createBackend } from "./factory.js";
import type { CallBackend, BackendDeps } from "./backend.js";
import { CallRegistry } from "./registry.js";
import { callsRoutes } from "../routes/calls.js";

declare module "fastify" {
  interface FastifyInstance {
    calls: CallService;
  }
}

export class CallService {
  readonly registry: CallRegistry;
  private readonly backend: CallBackend;
  private readonly config: Config;

  constructor(config: Config, log: BackendDeps["log"]) {
    this.config = config;
    this.registry = new CallRegistry(config.maxEventsPerCall);
    this.backend = createBackend(config.callBackend, config.ari, {
      registry: this.registry,
      log,
    });
  }

  get backendName(): string {
    return this.backend.name;
  }

  get routes() {
    return callsRoutes({
      config: this.config,
      registry: this.registry,
      backend: this.backend,
    });
  }

  /** Disposes timers/handles for every known call. */
  close(): void {
    for (const call of this.registry.list()) {
      this.backend.dispose(call.id);
    }
  }
}

export type { CallBackend };
