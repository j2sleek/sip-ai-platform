/**
 * Fastify application factory. Kept separate from server.ts so tests can build
 * the app without binding a network port.
 */

import Fastify, { type FastifyInstance } from "fastify";

import type { Config } from "./config.js";
import { healthRoutes } from "./routes/health.js";

export async function buildApp(config: Config): Promise<FastifyInstance> {
  const app = Fastify({
    logger: { level: config.logLevel },
  });

  await app.register(healthRoutes);

  return app;
}
