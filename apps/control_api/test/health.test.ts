/**
 * Health route + config tests. Uses Fastify's `inject` so no port is bound.
 * Run: npm test  (node --test with tsx loader)
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";

test("GET /health returns the HealthResponse contract", async () => {
  const app = await buildApp(loadConfig({ APP_ENV: "test", LOG_LEVEL: "error" }));
  const res = await app.inject({ method: "GET", url: "/health" });

  assert.equal(res.statusCode, 200);
  const body = res.json();
  assert.equal(body.status, "ok");
  assert.equal(body.service, "control_api");
  assert.equal(typeof body.version, "string");

  await app.close();
});

test("loadConfig is environment-driven", () => {
  const config = loadConfig({ APP_ENV: "prod", PORT: "1234", LOG_LEVEL: "warn" });
  assert.equal(config.appEnv, "prod");
  assert.equal(config.port, 1234);
  assert.equal(config.logLevel, "warn");
});

test("loadConfig rejects an invalid LOG_LEVEL", () => {
  assert.throws(() => loadConfig({ LOG_LEVEL: "loud" }));
});

test("loadConfig uses safe defaults", () => {
  const config = loadConfig({});
  assert.equal(config.appEnv, "development");
  assert.equal(config.port, 4000);
  assert.equal(config.logLevel, "info");
});
