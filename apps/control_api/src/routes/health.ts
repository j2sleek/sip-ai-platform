/**
 * Health route. Implements the shared HealthResponse contract:
 *   { status, service, version }
 */

import type { FastifyInstance } from "fastify";

export const SERVICE_NAME = "control_api";
export const SERVICE_VERSION = "0.1.0";

export interface HealthResponse {
  status: "ok";
  service: string;
  version: string;
}

export async function healthRoutes(app: FastifyInstance): Promise<void> {
  app.get("/health", async (): Promise<HealthResponse> => {
    return { status: "ok", service: SERVICE_NAME, version: SERVICE_VERSION };
  });
}
