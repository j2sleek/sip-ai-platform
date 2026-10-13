/**
 * Optional bearer-token guard for the control surface.
 *
 * When `CONTROL_API_TOKEN` is empty, auth is disabled (suitable for local
 * development only). When set, every `/api/v1/*` request must present
 * `Authorization: Bearer <token>`. Secrets are never logged.
 */

import type { FastifyReply, FastifyRequest } from "fastify";

export function makeAuthHook(token: string) {
  return async function authHook(
    request: FastifyRequest,
    reply: FastifyReply,
  ): Promise<void> {
    if (token === "") return;
    if (!request.url.startsWith("/api/")) return;

    const header = request.headers.authorization ?? "";
    const expected = `Bearer ${token}`;
    if (header !== expected) {
      await reply.code(401).send({
        error: { code: "unauthorized", message: "missing or invalid bearer token" },
      });
    }
  };
}
