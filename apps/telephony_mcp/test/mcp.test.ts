/**
 * End-to-end MCP test: an MCP Client talks to the telephony MCP server over an
 * in-memory transport pair, with the server backed by the stub control API.
 *
 * This exercises the real MCP protocol path (tool listing, tool calls, resource
 * reads) without spawning a process or binding stdio.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { ControlApiClient } from "../src/client.js";
import type { TelephonyConfig } from "../src/config.js";
import { createServer } from "../src/server.js";
import { startStubControlApi } from "./stub-control-api.js";

type AnyResult = {
  content?: Array<{ type: string; text?: string }>;
  isError?: boolean;
  contents?: Array<{ text?: string; mimeType?: string }>;
};

function textOf(result: AnyResult): string {
  const item = result.content?.find((c) => c.type === "text");
  assert.ok(item?.text, "expected a text content item");
  return item.text;
}

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

async function connect(baseUrl: string): Promise<{ mcp: Client; close: () => Promise<void> }> {
  const server = createServer(clientFor(baseUrl), { defaultWaitMs: 3000, maxWaitMs: 5000 });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);

  const mcp = new Client({ name: "test-client", version: "0.0.0" });
  await mcp.connect(clientTransport);

  return {
    mcp,
    close: async () => {
      await mcp.close();
      await server.close();
    },
  };
}

test("lists the telephony tools", async () => {
  const stub = await startStubControlApi();
  const { mcp, close } = await connect(stub.baseUrl);
  try {
    const tools = await mcp.listTools();
    const names = tools.tools.map((t) => t.name).sort();
    assert.deepEqual(names, [
      "get_call",
      "get_transcript",
      "hangup",
      "list_calls",
      "originate_call",
      "speak",
      "wait_for_input",
    ]);
  } finally {
    await close();
    await stub.close();
  }
});

test("originate_call → wait_for_input → get_transcript over MCP", async () => {
  const stub = await startStubControlApi();
  const { mcp, close } = await connect(stub.baseUrl);
  try {
    const originated = (await mcp.callTool({
      name: "originate_call",
      arguments: { to: "1000", greeting: "Hello from the agent" },
    })) as AnyResult;
    assert.notEqual(originated.isError, true);
    const call = JSON.parse(textOf(originated)) as { id: string; to: string };
    assert.equal(call.to, "1000");

    const waited = (await mcp.callTool({
      name: "wait_for_input",
      arguments: { call_id: call.id, timeout_ms: 3000 },
    })) as AnyResult;
    const wait = JSON.parse(textOf(waited)) as { utterance: string | null; timedOut: boolean };
    assert.equal(wait.timedOut, false);
    assert.ok(wait.utterance);

    const transcript = (await mcp.callTool({
      name: "get_transcript",
      arguments: { call_id: call.id },
    })) as AnyResult;
    const turns = JSON.parse(textOf(transcript)) as { transcript: Array<{ role: string }> };
    assert.equal(turns.transcript[0]!.role, "agent");

    // The transcript resource returns the same data over the resource path.
    const resource = (await mcp.readResource({
      uri: `call://${call.id}/transcript`,
    })) as AnyResult;
    const body = JSON.parse(resource.contents![0]!.text!) as {
      call_id: string;
      transcript: unknown[];
    };
    assert.equal(body.call_id, call.id);
    assert.ok(body.transcript.length >= 2);
  } finally {
    await close();
    await stub.close();
  }
});

test("speak and hangup over MCP", async () => {
  const stub = await startStubControlApi();
  const { mcp, close } = await connect(stub.baseUrl);
  try {
    const originated = (await mcp.callTool({
      name: "originate_call",
      arguments: { to: "1000" },
    })) as AnyResult;
    const call = JSON.parse(textOf(originated)) as { id: string };

    const spoken = (await mcp.callTool({
      name: "speak",
      arguments: { call_id: call.id, text: "Please hold." },
    })) as AnyResult;
    assert.notEqual(spoken.isError, true);

    const ended = (await mcp.callTool({
      name: "hangup",
      arguments: { call_id: call.id },
    })) as AnyResult;
    const endedCall = JSON.parse(textOf(ended)) as { state: string };
    assert.equal(endedCall.state, "ended");
  } finally {
    await close();
    await stub.close();
  }
});

test("tool errors are returned as isError, not thrown", async () => {
  const stub = await startStubControlApi();
  const { mcp, close } = await connect(stub.baseUrl);
  try {
    const result = (await mcp.callTool({
      name: "get_call",
      arguments: { call_id: "does-not-exist" },
    })) as AnyResult;
    assert.equal(result.isError, true);
    const body = JSON.parse(textOf(result)) as { error: { code: string } };
    assert.equal(body.error.code, "control_api_http_error");
  } finally {
    await close();
    await stub.close();
  }
});
