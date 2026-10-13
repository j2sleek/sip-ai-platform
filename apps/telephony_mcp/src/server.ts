/**
 * Telephony MCP server.
 *
 * Exposes call control to an AI brain (e.g. OpenCode) over MCP so voice becomes
 * one more input/output modality for the brain:
 *
 *   Tools:
 *     originate_call   place an outbound call
 *     list_calls       list known calls
 *     get_call         call status + transcript
 *     speak            have the agent speak text on a call
 *     wait_for_input   long-poll for the next caller utterance
 *     hangup           end a call
 *     get_transcript   caller/agent turns for a call
 *
 *   Resource:
 *     call://{id}/transcript  (application/json)
 *
 * The server is a thin adapter over control_api; it owns no call state. It uses
 * stdio transport, so protocol messages travel on stdout — all logging MUST go
 * to stderr.
 */

import { McpServer, ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

import { ControlApiClient, ControlApiError } from "./client.js";
import { loadConfig } from "./config.js";

export const SERVER_NAME = "telephony_mcp";
export const SERVER_VERSION = "0.1.0";

type ToolResult = {
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
};

function ok(data: unknown): ToolResult {
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

function fail(err: unknown): ToolResult {
  const code = err instanceof ControlApiError ? err.code : "mcp_error";
  const message = err instanceof Error ? err.message : String(err);
  return {
    content: [{ type: "text", text: JSON.stringify({ error: { code, message } }, null, 2) }],
    isError: true,
  };
}

export function createServer(client: ControlApiClient, waitDefaults: {
  defaultWaitMs: number;
  maxWaitMs: number;
}): McpServer {
  const server = new McpServer({ name: SERVER_NAME, version: SERVER_VERSION });

  server.registerTool(
    "originate_call",
    {
      title: "Originate call",
      description:
        "Place an outbound voice call to a destination and bind it to the voice agent. " +
        "Returns a call_id used by the other tools.",
      inputSchema: {
        to: z.string().describe("Destination: SIP URI, extension, or E.164 number"),
        from: z.string().optional().describe("Caller ID to present"),
        greeting: z
          .string()
          .optional()
          .describe("Optional first line the agent speaks when the call is answered"),
      },
    },
    async ({ to, from, greeting }) => {
      try {
        return ok(await client.originateCall({ to, from, greeting }));
      } catch (err) {
        return fail(err);
      }
    },
  );

  server.registerTool(
    "list_calls",
    {
      title: "List calls",
      description: "List known calls (most recent first).",
      inputSchema: {},
    },
    async () => {
      try {
        return ok({ calls: await client.listCalls() });
      } catch (err) {
        return fail(err);
      }
    },
  );

  server.registerTool(
    "get_call",
    {
      title: "Get call",
      description: "Get a call's current status and transcript.",
      inputSchema: { call_id: z.string().describe("The call_id returned by originate_call") },
    },
    async ({ call_id }) => {
      try {
        return ok(await client.getCall(call_id));
      } catch (err) {
        return fail(err);
      }
    },
  );

  server.registerTool(
    "speak",
    {
      title: "Speak",
      description: "Have the voice agent speak the given text on an active call.",
      inputSchema: {
        call_id: z.string().describe("The call_id"),
        text: z.string().describe("Text for the agent to say"),
      },
    },
    async ({ call_id, text }) => {
      try {
        return ok(await client.speak(call_id, text));
      } catch (err) {
        return fail(err);
      }
    },
  );

  server.registerTool(
    "wait_for_input",
    {
      title: "Wait for input",
      description:
        "Wait for the caller's next utterance on a call. Returns " +
        "{ utterance, cursor, timed_out, call_ended }. Pass the returned cursor " +
        "back as after_seq to read subsequent utterances.",
      inputSchema: {
        call_id: z.string().describe("The call_id"),
        after_seq: z
          .number()
          .int()
          .optional()
          .describe("Return only utterances after this event sequence (cursor)"),
        timeout_ms: z
          .number()
          .int()
          .optional()
          .describe("Maximum time to wait, in milliseconds"),
      },
    },
    async ({ call_id, after_seq, timeout_ms }) => {
      try {
        const wait = Math.min(
          timeout_ms ?? waitDefaults.defaultWaitMs,
          waitDefaults.maxWaitMs,
        );
        const result = await client.waitForInput(call_id, after_seq ?? 0, wait);
        return ok(result);
      } catch (err) {
        return fail(err);
      }
    },
  );

  server.registerTool(
    "hangup",
    {
      title: "Hang up",
      description: "End an active call.",
      inputSchema: { call_id: z.string().describe("The call_id") },
    },
    async ({ call_id }) => {
      try {
        return ok(await client.hangup(call_id));
      } catch (err) {
        return fail(err);
      }
    },
  );

  server.registerTool(
    "get_transcript",
    {
      title: "Get transcript",
      description: "Return the caller/agent turns recorded for a call.",
      inputSchema: { call_id: z.string().describe("The call_id") },
    },
    async ({ call_id }) => {
      try {
        return ok({ transcript: await client.transcript(call_id) });
      } catch (err) {
        return fail(err);
      }
    },
  );

  server.registerResource(
    "call_transcript",
    new ResourceTemplate("call://{id}/transcript", {
      list: async () => {
        const calls = await client.listCalls();
        return {
          resources: calls.map((call) => ({
            uri: `call://${call.id}/transcript`,
            name: `Transcript for call ${call.id}`,
            description: `Caller/agent turns for call ${call.id}`,
            mimeType: "application/json",
          })),
        };
      },
    }),
    {
      title: "Call transcript",
      description: "Caller/agent turns for a call, as JSON.",
      mimeType: "application/json",
    },
    async (uri, variables) => {
      const id = String(variables.id);
      const turns = await client.transcript(id);
      return {
        contents: [
          {
            uri: uri.href,
            mimeType: "application/json",
            text: JSON.stringify({ call_id: id, transcript: turns }, null, 2),
          },
        ],
      };
    },
  );

  return server;
}

/** Connects a stdio MCP server. Logging goes to stderr to keep stdout clean. */
export async function main(): Promise<void> {
  const config = loadConfig();
  const client = new ControlApiClient(config);
  const server = createServer(client, {
    defaultWaitMs: config.defaultWaitMs,
    maxWaitMs: config.maxWaitMs,
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(
    JSON.stringify({
      service: SERVER_NAME,
      event: "listening",
      control_api: config.controlApiUrl,
    }),
  );
}

// Run when executed directly (not when imported by tests).
const isMain = process.argv[1] !== undefined && import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  main().catch((err) => {
    console.error(JSON.stringify({ service: SERVER_NAME, event: "fatal", error: String(err) }));
    process.exit(1);
  });
}
