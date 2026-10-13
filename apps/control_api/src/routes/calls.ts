/**
 * Call control routes (the outbound-call API and the surface the telephony MCP
 * server drives).
 *
 *   POST /api/v1/calls                originate a call
 *   GET  /api/v1/calls                list calls
 *   GET  /api/v1/calls/:id            call status
 *   POST /api/v1/calls/:id/speak      have the agent speak text
 *   POST /api/v1/calls/:id/hangup     end the call
 *   GET  /api/v1/calls/:id/events     long-poll for new events (transcript)
 */

import type { FastifyInstance } from "fastify";

import type { Config } from "../config.js";
import type { CallBackend } from "../calls/backend.js";
import type { CallRegistry } from "../calls/registry.js";
import { AriError } from "../calls/ari.js";
import type { CallRecord } from "../calls/types.js";

interface CallsDeps {
  config: Config;
  registry: CallRegistry;
  backend: CallBackend;
}

interface OriginateBody {
  to?: unknown;
  from?: unknown;
  greeting?: unknown;
}

function publicCall(call: CallRecord): Omit<CallRecord, "meta"> {
  // meta may hold backend internals; keep it out of the public shape.
  const { meta: _meta, ...rest } = call;
  return rest;
}

export function callsRoutes(deps: CallsDeps) {
  const { config, registry, backend } = deps;

  return async function register(app: FastifyInstance): Promise<void> {
    app.post("/api/v1/calls", async (request, reply) => {
      const body = (request.body ?? {}) as OriginateBody;
      const to = typeof body.to === "string" ? body.to.trim() : "";
      if (to === "") {
        return reply
          .code(400)
          .send({ error: { code: "bad_request", message: "'to' is required" } });
      }

      try {
        const originated = await backend.originate({
          to,
          from: typeof body.from === "string" ? body.from : undefined,
          greeting: typeof body.greeting === "string" ? body.greeting : undefined,
        });
        const call = registry.get(originated.id)!;
        return reply.code(201).send({ call: publicCall(call) });
      } catch (err) {
        return sendBackendError(reply, "originate", err);
      }
    });

    app.get("/api/v1/calls", async () => {
      return { calls: registry.list().map(publicCall) };
    });

    app.get<{ Params: { id: string } }>("/api/v1/calls/:id", async (request, reply) => {
      const call = registry.get(request.params.id);
      if (!call) {
        return reply
          .code(404)
          .send({ error: { code: "not_found", message: "unknown call" } });
      }
      return { call: publicCall(call) };
    });

    app.post<{ Params: { id: string } }>(
      "/api/v1/calls/:id/speak",
      async (request, reply) => {
        const call = registry.get(request.params.id);
        if (!call) {
          return reply
            .code(404)
            .send({ error: { code: "not_found", message: "unknown call" } });
        }
        const body = (request.body ?? {}) as { text?: unknown };
        const text = typeof body.text === "string" ? body.text : "";
        if (text.trim() === "") {
          return reply
            .code(400)
            .send({ error: { code: "bad_request", message: "'text' is required" } });
        }
        try {
          await backend.speak(call.id, text);
          return reply.code(202).send({ call: publicCall(registry.get(call.id)!) });
        } catch (err) {
          return sendBackendError(reply, "speak", err);
        }
      },
    );

    app.post<{ Params: { id: string } }>(
      "/api/v1/calls/:id/hangup",
      async (request, reply) => {
        const call = registry.get(request.params.id);
        if (!call) {
          return reply
            .code(404)
            .send({ error: { code: "not_found", message: "unknown call" } });
        }
        try {
          await backend.hangup(call.id);
          return reply.code(200).send({ call: publicCall(registry.get(call.id)!) });
        } catch (err) {
          return sendBackendError(reply, "hangup", err);
        }
      },
    );

    app.get<{ Params: { id: string }; Querystring: { since?: string; wait?: string } }>(
      "/api/v1/calls/:id/events",
      async (request, reply) => {
        const call = registry.get(request.params.id);
        if (!call) {
          return reply
            .code(404)
            .send({ error: { code: "not_found", message: "unknown call" } });
        }

        const since = Number.parseInt(request.query.since ?? "0", 10);
        const sinceSeq = Number.isFinite(since) && since > 0 ? since : 0;
        let waitMs = Number.parseInt(request.query.wait ?? "0", 10);
        if (!Number.isFinite(waitMs) || waitMs < 0) waitMs = 0;
        waitMs = Math.min(waitMs, config.maxEventWaitMs);

        const events =
          waitMs > 0
            ? await registry.waitForEvents(call.id, sinceSeq, waitMs)
            : registry.eventsSince(call.id, sinceSeq);

        return {
          events,
          call: publicCall(registry.get(call.id)!),
          cursor: events.length > 0 ? events[events.length - 1]!.seq : sinceSeq,
        };
      },
    );
  };
}

function sendBackendError(
  reply: { code: (n: number) => { send: (body: unknown) => unknown } },
  action: string,
  err: unknown,
) {
  if (err instanceof AriError) {
    const status = err.status !== undefined && err.status >= 400 && err.status < 500 ? 502 : 502;
    return reply.code(status).send({
      error: { code: err.code, message: `ari ${action} failed: ${err.message}` },
    });
  }
  return reply.code(500).send({
    error: { code: "backend_error", message: `${action} failed: ${(err as Error).message}` },
  });
}
