#!/usr/bin/env node
/**
 * End-to-end voice-loop demo.
 *
 * Demonstrates the platform's brain-side loop with NO telephony stack required:
 *
 *   this script (stands in for the AI brain)
 *        │  MCP over stdio (real protocol)
 *        ▼
 *   telephony_mcp  ──HTTP──▶  control_api (CALL_BACKEND=simulated)
 *
 * It starts control_api as a child process, connects to telephony_mcp over a
 * real stdio transport as an MCP client, then runs a scripted conversation:
 *
 *   originate_call → (greeting) → wait_for_input → speak → wait_for_input …
 *   → get_transcript → read resource → hangup
 *
 * Usage:
 *   node apps/telephony_mcp/scripts/demo-voice-loop.mjs
 *
 * Prerequisites: build both apps first.
 *   (cd apps/control_api && npm install && npm run build)
 *   (cd apps/telephony_mcp && npm install && npm run build)
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..", "..");
const CONTROL_API_DIR = resolve(REPO, "apps", "control_api");
const TELEPHONY_DIR = resolve(REPO, "apps", "telephony_mcp");

const CONTROL_API_PORT = Number(process.env.DEMO_CONTROL_API_PORT ?? 4111);
const CONTROL_API_URL = `http://127.0.0.1:${CONTROL_API_PORT}`;
const MAX_EXCHANGES = Number(process.env.DEMO_MAX_EXCHANGES ?? 3);

const BRAIN_REPLIES = [
  "Great — I'll note that. Anything else you'd like me to change?",
  "Understood. I'll open a task for it and keep you posted.",
  "Done. I'll call you again once the work is committed.",
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function requireBuilds() {
  const controlApi = resolve(CONTROL_API_DIR, "dist", "server.js");
  const telephony = resolve(TELEPHONY_DIR, "dist", "server.js");
  for (const [label, path] of [
    ["control_api", controlApi],
    ["telephony_mcp", telephony],
  ]) {
    if (!existsSync(path)) {
      console.error(`Missing build output for ${label}: ${path}`);
      console.error("Run `npm install && npm run build` in that app first.");
      process.exit(1);
    }
  }
}

async function waitForHealth(url, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${url}/health`);
      if (res.ok) return true;
    } catch {
      // not up yet
    }
    await sleep(100);
  }
  throw new Error(`control_api did not become healthy at ${url}/health`);
}

function startControlApi() {
  const child = spawn("node", ["dist/server.js"], {
    cwd: CONTROL_API_DIR,
    env: {
      ...process.env,
      APP_ENV: "demo",
      HOST: "127.0.0.1",
      PORT: String(CONTROL_API_PORT),
      LOG_LEVEL: process.env.DEMO_LOG_LEVEL ?? "warn",
      CALL_BACKEND: "simulated",
      CONTROL_API_TOKEN: "",
    },
    stdio: ["ignore", "inherit", "inherit"],
  });
  return child;
}

function textOf(result) {
  const item = result.content?.find((c) => c.type === "text");
  if (!item?.text) throw new Error("expected a text tool result");
  return JSON.parse(item.text);
}

function printTurn(turn) {
  const who = turn.role === "agent" ? "AGENT" : "CALLER";
  console.log(`  ${who.padEnd(6)} │ ${turn.text}`);
}

async function main() {
  requireBuilds();

  console.log("SIP AI Platform — voice-loop demo (simulated telephony)\n");
  console.log(`Starting control_api on ${CONTROL_API_URL} …`);
  const controlApi = startControlApi();

  let client;
  try {
    await waitForHealth(CONTROL_API_URL);
    console.log("control_api healthy.\n");

    const transport = new StdioClientTransport({
      command: "node",
      args: ["dist/server.js"],
      cwd: TELEPHONY_DIR,
      env: { ...process.env, CONTROL_API_URL, CONTROL_API_TOKEN: "" },
      stderr: "inherit",
    });
    client = new Client({ name: "demo-brain", version: "0.0.0" });
    await client.connect(transport);

    const tools = await client.listTools();
    console.log(`Connected to telephony_mcp. Tools: ${tools.tools.map((t) => t.name).join(", ")}\n`);

    const call = textOf(
      await client.callTool({
        name: "originate_call",
        arguments: {
          to: "1000",
          from: "build-assistant",
          greeting: "Hi! It's your build assistant — I have an update on the voice platform.",
        },
      }),
    );
    console.log(`Placed call ${call.id} → ${call.to} (state=${call.state})\n`);
    console.log("Conversation:");
    console.log("  -------┼--------------------------------------------------");

    let cursor = 0;
    let exchange = 0;
    while (exchange < MAX_EXCHANGES) {
      const wait = textOf(
        await client.callTool({
          name: "wait_for_input",
          arguments: { call_id: call.id, after_seq: cursor, timeout_ms: 4000 },
        }),
      );

      if (wait.utterance) {
        printTurn({ role: "user", text: wait.utterance });
        cursor = wait.cursor;
      }
      if (wait.callEnded) {
        console.log("  (call ended)");
        break;
      }
      if (wait.timedOut && !wait.utterance) {
        console.log("  (no further input; ending the conversation)");
        break;
      }

      const reply = BRAIN_REPLIES[exchange % BRAIN_REPLIES.length];
      await client.callTool({ name: "speak", arguments: { call_id: call.id, text: reply } });
      printTurn({ role: "agent", text: reply });
      exchange += 1;
    }

    console.log("  -------┼--------------------------------------------------\n");

    const transcript = textOf(
      await client.callTool({ name: "get_transcript", arguments: { call_id: call.id } }),
    );
    console.log(`Transcript has ${transcript.transcript.length} turns (via get_transcript).`);

    const resource = await client.readResource({ uri: `call://${call.id}/transcript` });
    const resBody = JSON.parse(resource.contents[0].text);
    console.log(
      `Transcript resource call://${call.id}/transcript returned ${resBody.transcript.length} turns.`,
    );

    const ended = textOf(await client.callTool({ name: "hangup", arguments: { call_id: call.id } }));
    console.log(`Hung up call ${ended.id} (state=${ended.state}).`);

    console.log("\nVoice-loop demo completed successfully.");
  } finally {
    if (client) await client.close().catch(() => {});
    controlApi.kill("SIGTERM");
  }
}

main().catch((err) => {
  console.error(`\nDemo failed: ${err instanceof Error ? err.stack : err}`);
  process.exit(1);
});
