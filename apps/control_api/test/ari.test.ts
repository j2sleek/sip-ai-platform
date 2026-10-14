/**
 * ARI client/backend tests against a local stub HTTP server (no Asterisk).
 *
 * Run: npm test
 */

import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { test } from "node:test";

import { AriBackend, AriClient, AriError } from "../src/calls/ari.js";
import { CallRegistry } from "../src/calls/registry.js";
import type { AriConfig } from "../src/config.js";

interface Recorded {
  method: string;
  url: string;
}

function startStub(): Promise<{
  baseUrl: string;
  requests: Recorded[];
  close: () => Promise<void>;
}> {
  const requests: Recorded[] = [];
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    requests.push({ method: req.method ?? "", url: req.url ?? "" });
    if (req.url?.startsWith("/ari/channels?") || req.url === "/ari/channels") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ id: new URL(req.url, "http://x").searchParams.get("channelId") }));
      return;
    }
    res.writeHead(204);
    res.end();
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      resolve({
        baseUrl: `http://127.0.0.1:${port}`,
        requests,
        close: () =>
          new Promise((done) => {
            server.close(() => done());
          }),
      });
    });
  });
}

const ariConfig = (baseUrl: string): AriConfig => ({
  baseUrl,
  username: "voice_core",
  password: "secret",
  app: "voice_core",
  timeoutMs: 2000,
  endpointTemplate: "PJSIP/{to}",
  callerId: '"AI Assistant" <2000>',
});

const silentLog = { info: () => {}, warn: () => {}, error: () => {} };

test("AriClient originates, plays, and hangs up", async () => {
  const stub = await startStub();
  try {
    const client = new AriClient({ config: ariConfig(stub.baseUrl) });
    const originated = await client.originate({
      channelId: "chan-1",
      endpoint: "PJSIP/1000",
      app: "voice_core",
      callerId: "agent",
    });
    assert.equal(originated.id, "chan-1");
    await client.play("chan-1", "sound:hello");
    await client.hangup("chan-1");

    assert.equal(stub.requests[0]!.method, "POST");
    assert.match(stub.requests[0]!.url, /endpoint=PJSIP%2F1000/);
    assert.equal(stub.requests[2]!.method, "DELETE");
  } finally {
    await stub.close();
  }
});

test("AriClient classifies HTTP errors", async () => {
  const server = createServer((_req, res) => {
    res.writeHead(500);
    res.end("boom");
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;

  try {
    const client = new AriClient({ config: ariConfig(`http://127.0.0.1:${port}`) });
    await assert.rejects(
      () => client.hangup("chan-1"),
      (err: unknown) => err instanceof AriError && err.code === "ari_http_error",
    );
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("AriClient normalises a base URL that already includes /ari", async () => {
  const stub = await startStub();
  try {
    const client = new AriClient({ config: ariConfig(`${stub.baseUrl}/ari`) });
    await client.originate({
      channelId: "chan-1",
      endpoint: "PJSIP/1000",
      app: "voice_core",
    });
    assert.match(stub.requests[0]!.url, /^\/ari\/channels\?/);
  } finally {
    await stub.close();
  }
});

test("AriBackend originate expands the endpoint template and records events", async () => {
  const stub = await startStub();
  try {
    const registry = new CallRegistry(100);
    const backend = new AriBackend(ariConfig(stub.baseUrl), { registry, log: silentLog });
    const originated = await backend.originate({ to: "1000", from: "agent" });

    const call = registry.get(originated.id)!;
    assert.equal(call.backend, "ari");
    assert.equal(call.state, "ringing");
    assert.equal(call.meta.endpoint, "PJSIP/1000");

    await backend.speak(originated.id, "hello");
    await backend.hangup(originated.id);
    assert.equal(registry.get(originated.id)!.state, "ended");
  } finally {
    await stub.close();
  }
});

test("AriBackend presents the configured caller ID when the request omits from", async () => {
  const stub = await startStub();
  try {
    const registry = new CallRegistry(100);
    const config = { ...ariConfig(stub.baseUrl), callerId: '"AI Assistant" <2000>' };
    const backend = new AriBackend(config, { registry, log: silentLog });

    await backend.originate({ to: "1000" });

    const query = new URLSearchParams(stub.requests[0]!.url.split("?")[1] ?? "");
    assert.equal(query.get("callerId"), '"AI Assistant" <2000>');
  } finally {
    await stub.close();
  }
});

test("AriBackend marks the call failed when originate fails", async () => {
  const server = createServer((_req, res) => {
    res.writeHead(503);
    res.end("unavailable");
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;

  try {
    const registry = new CallRegistry(100);
    const backend = new AriBackend(ariConfig(`http://127.0.0.1:${port}`), {
      registry,
      log: silentLog,
    });
    await assert.rejects(() => backend.originate({ to: "1000" }));
    const call = registry.list()[0]!;
    assert.equal(call.state, "failed");
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
