/**
 * ControlApiClient tests against the in-memory stub control API.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { ControlApiClient, ControlApiError, toTranscript } from "../src/client.js";
import type { TelephonyConfig } from "../src/config.js";
import { startStubControlApi } from "./stub-control-api.js";

function clientFor(baseUrl: string): ControlApiClient {
  const config: TelephonyConfig = {
    controlApiUrl: baseUrl,
    controlToken: "",
    requestTimeoutMs: 5000,
    defaultWaitMs: 3000,
    maxWaitMs: 5000,
  };
  return new ControlApiClient(config);
}

test("originate + getCall returns a call with transcript", async () => {
  const stub = await startStubControlApi();
  try {
    const client = clientFor(stub.baseUrl);
    const call = await client.originateCall({ to: "1000", greeting: "Welcome" });
    assert.equal(call.to, "1000");

    const detail = await client.getCall(call.id);
    assert.equal(detail.id, call.id);
    assert.ok(Array.isArray(detail.transcript));
  } finally {
    await stub.close();
  }
});

test("waitForInput resolves with the caller utterance", async () => {
  const stub = await startStubControlApi();
  try {
    const client = clientFor(stub.baseUrl);
    const call = await client.originateCall({ to: "1000" });
    const result = await client.waitForInput(call.id, 0, 3000);
    assert.equal(result.timedOut, false);
    assert.ok(result.utterance);
    assert.ok(result.cursor > 0);
  } finally {
    await stub.close();
  }
});

test("waitForInput respects after_seq", async () => {
  const stub = await startStubControlApi();
  try {
    const client = clientFor(stub.baseUrl);
    const call = await client.originateCall({ to: "1000" });

    const first = await client.waitForInput(call.id, 0, 3000);
    assert.ok(first.utterance);

    // Nothing new after the first utterance within a short window.
    const second = await client.waitForInput(call.id, first.cursor, 200);
    assert.equal(second.timedOut, true);
    assert.equal(second.utterance, null);
  } finally {
    await stub.close();
  }
});

test("transcript records agent and user turns in order", async () => {
  const stub = await startStubControlApi();
  try {
    const client = clientFor(stub.baseUrl);
    const call = await client.originateCall({ to: "1000", greeting: "Hi" });
    await client.waitForInput(call.id, 0, 3000);

    const turns = await client.transcript(call.id);
    assert.equal(turns[0]!.role, "agent");
    assert.equal(turns[0]!.text, "Hi");
    assert.equal(turns[1]!.role, "user");
  } finally {
    await stub.close();
  }
});

test("speak and hangup update the call", async () => {
  const stub = await startStubControlApi();
  try {
    const client = clientFor(stub.baseUrl);
    const call = await client.originateCall({ to: "1000" });
    await client.speak(call.id, "Please hold.");
    const ended = await client.hangup(call.id);
    assert.equal(ended.state, "ended");
    assert.ok(ended.endedAt);
  } finally {
    await stub.close();
  }
});

test("unknown call surfaces a typed error", async () => {
  const stub = await startStubControlApi();
  try {
    const client = clientFor(stub.baseUrl);
    await assert.rejects(
      () => client.getCall("missing"),
      (err: unknown) => err instanceof ControlApiError && err.status === 404,
    );
  } finally {
    await stub.close();
  }
});

test("transport errors are classified", async () => {
  // Point at a closed port.
  const client = clientFor("http://127.0.0.1:1");
  await assert.rejects(
    () => client.listCalls(),
    (err: unknown) => err instanceof ControlApiError,
  );
});

test("toTranscript maps only utterance events", () => {
  const turns = toTranscript([
    { seq: 1, at: "t", type: "call.created", data: {} },
    { seq: 2, at: "t", type: "utterance.agent", data: { text: "a" } },
    { seq: 3, at: "t", type: "utterance.user", data: { text: "b" } },
  ]);
  assert.deepEqual(turns, [
    { role: "agent", text: "a", at: "t" },
    { role: "user", text: "b", at: "t" },
  ]);
});
