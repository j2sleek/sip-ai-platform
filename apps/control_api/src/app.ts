/**
 * Fastify application factory. Kept separate from server.ts so tests can build
 * the app without binding a network port.
 */

import Fastify, { type FastifyInstance } from "fastify";

import { makeAuthHook } from "./auth.js";
import { CallService } from "./calls/service.js";
import type { Config } from "./config.js";
import { healthRoutes } from "./routes/health.js";

export async function buildApp(config: Config): Promise<FastifyInstance> {
  const app = Fastify({
    logger: { level: config.logLevel },
  });

  app.addHook("onRequest", makeAuthHook(config.controlToken));
  await app.register(healthRoutes);

  const calls = new CallService(config, app.log);
  app.decorate("calls", calls);
  await app.register(calls.routes);

  app.addHook("onClose", async () => {
    calls.close();
  });

  return app;
}
