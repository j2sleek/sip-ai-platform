/**
 * Call control route tests. Uses Fastify's `inject` so no port is bound, and the
 * default `simulated` backend so no telephony is required.
 *
 * Run: npm test  (node --test with tsx loader)
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";

function testConfig(overrides: Record<string, string> = {}) {
  return loadConfig({ APP_ENV: "test", LOG_LEVEL: "error", CALL_BACKEND: "simulated", ...overrides });
}

type App = Awaited<ReturnType<typeof buildApp>>;

/** Drains events from `cursor` until one of `type` appears (or times out). */
async function awaitEvent(
  app: App,
  id: string,
  type: string,
  timeoutMs = 3000,
): Promise<{ type: string; data: Record<string, unknown> }> {
  let cursor = 0;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const remaining = Math.max(1, deadline - Date.now());
    const res = await app.inject({
      method: "GET",
      url: `/api/v1/calls/${id}/events?since=${cursor}&wait=${remaining}`,
    });
    const body = res.json();
    cursor = body.cursor;
    const match = body.events.find((e: { type: string }) => e.type === type);
    if (match) return match;
  }
  throw new Error(`event ${type} not seen for call ${id}`);
}

test("POST /api/v1/calls originates a call", async () => {
  const app = await buildApp(testConfig());
  const res = await app.inject({
    method: "POST",
    url: "/api/v1/calls",
    payload: { to: "1000", from: "agent" },
  });

  assert.equal(res.statusCode, 201);
  const body = res.json();
  assert.equal(body.call.to, "1000");
  assert.equal(body.call.from, "agent");
  assert.equal(body.call.backend, "simulated");
  assert.ok(["queued", "ringing", "answered", "active"].includes(body.call.state));

  await app.close();
});

test("originate rejects a missing destination", async () => {
  const app = await buildApp(testConfig());
  const res = await app.inject({ method: "POST", url: "/api/v1/calls", payload: {} });
  assert.equal(res.statusCode, 400);
  assert.equal(res.json().error.code, "bad_request");
  await app.close();
});

test("events long-poll returns the greeting then the caller reply", async () => {
  const app = await buildApp(testConfig());
  const created = await app.inject({
    method: "POST",
    url: "/api/v1/calls",
    payload: { to: "1000", greeting: "Hello from the agent" },
  });
  const id = created.json().call.id;

  const agent = await awaitEvent(app, id, "utterance.agent");
  assert.equal(agent.data.text, "Hello from the agent");

  const user = await awaitEvent(app, id, "utterance.user");
  assert.equal(typeof user.data.text, "string");

  await app.close();
});

test("speak posts an agent utterance", async () => {
  const app = await buildApp(testConfig());
  const created = await app.inject({
    method: "POST",
    url: "/api/v1/calls",
    payload: { to: "1000" },
  });
  const id = created.json().call.id;

  const res = await app.inject({
    method: "POST",
    url: `/api/v1/calls/${id}/speak`,
    payload: { text: "Please confirm the meeting." },
  });
  assert.equal(res.statusCode, 202);
  assert.equal(res.json().call.state, "active");

  await app.close();
});

test("hangup ends the call", async () => {
  const app = await buildApp(testConfig());
  const created = await app.inject({
    method: "POST",
    url: "/api/v1/calls",
    payload: { to: "1000" },
  });
  const id = created.json().call.id;

  const res = await app.inject({ method: "POST", url: `/api/v1/calls/${id}/hangup` });
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().call.state, "ended");
  assert.ok(res.json().call.endedAt);

  await app.close();
});

test("unknown call is 404", async () => {
  const app = await buildApp(testConfig());
  const res = await app.inject({ method: "GET", url: "/api/v1/calls/nope" });
  assert.equal(res.statusCode, 404);
  await app.close();
});

test("list returns originated calls", async () => {
  const app = await buildApp(testConfig());
  await app.inject({ method: "POST", url: "/api/v1/calls", payload: { to: "1000" } });
  await app.inject({ method: "POST", url: "/api/v1/calls", payload: { to: "1001" } });
  const res = await app.inject({ method: "GET", url: "/api/v1/calls" });
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().calls.length, 2);
  await app.close();
});

test("bearer auth guards /api/v1 when a token is configured", async () => {
  const app = await buildApp(testConfig({ CONTROL_API_TOKEN: "secret-token" }));

  const denied = await app.inject({ method: "GET", url: "/api/v1/calls" });
  assert.equal(denied.statusCode, 401);

  const allowed = await app.inject({
    method: "GET",
    url: "/api/v1/calls",
    headers: { authorization: "Bearer secret-token" },
  });
  assert.equal(allowed.statusCode, 200);

  // Health remains public.
  const health = await app.inject({ method: "GET", url: "/health" });
  assert.equal(health.statusCode, 200);

  await app.close();
});
