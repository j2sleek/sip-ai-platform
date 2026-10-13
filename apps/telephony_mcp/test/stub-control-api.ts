/**
 * A minimal in-memory stand-in for control_api, used by telephony_mcp tests.
 * Mirrors the event/long-poll behaviour so the MCP tools can be exercised
 * end-to-end without a real control_api process.
 */

import { randomUUID } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

interface Ev {
  seq: number;
  at: string;
  type: string;
  data: Record<string, unknown>;
}

interface StubCall {
  id: string;
  to: string;
  from: string;
  state: string;
  backend: string;
  createdAt: string;
  endedAt: string | null;
  events: Ev[];
}

type Waiter = (call: StubCall) => void;

export interface StubControlApi {
  baseUrl: string;
  calls: Map<string, StubCall>;
  close: () => Promise<void>;
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (chunk) => (data += chunk));
    req.on("end", () => resolve(data));
  });
}

export function startStubControlApi(): Promise<StubControlApi> {
  const calls = new Map<string, StubCall>();
  const waiters = new Set<Waiter>();

  const emit = (call: StubCall, type: string, data: Record<string, unknown> = {}): void => {
    const seq = call.events.length === 0 ? 1 : call.events[call.events.length - 1]!.seq + 1;
    call.events.push({ seq, at: new Date().toISOString(), type, data });
    for (const waiter of [...waiters]) {
      waiters.delete(waiter);
      waiter(call);
    }
  };

  let replyIndex = 0;
  const userReplies = ["Yes please.", "Tell me more."];

  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    const send = (status: number, body: unknown): void => {
      const payload = JSON.stringify(body);
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(payload);
    };

    if (req.method === "POST" && url.pathname === "/api/v1/calls") {
      const body = JSON.parse((await readBody(req)) || "{}");
      const call: StubCall = {
        id: randomUUID(),
        to: String(body.to ?? ""),
        from: String(body.from ?? "voice_core"),
        state: "ringing",
        backend: "simulated",
        createdAt: new Date().toISOString(),
        endedAt: null,
        events: [],
      };
      calls.set(call.id, call);
      emit(call, "call.created", { to: call.to });
      setTimeout(() => {
        call.state = "active";
        emit(call, "call.answered");
        emit(call, "utterance.agent", { text: body.greeting ?? "Hello" });
        setTimeout(() => {
          emit(call, "utterance.user", { text: userReplies[replyIndex % userReplies.length]! });
          replyIndex += 1;
        }, 100);
      }, 20);
      return send(201, { call });
    }

    if (req.method === "GET" && url.pathname === "/api/v1/calls") {
      return send(200, { calls: [...calls.values()] });
    }

    const eventsMatch = /^\/api\/v1\/calls\/([^/]+)\/events$/.exec(url.pathname);
    if (req.method === "GET" && eventsMatch) {
      const call = calls.get(eventsMatch[1]!);
      if (!call) return send(404, { error: { code: "not_found", message: "unknown call" } });
      const since = Number.parseInt(url.searchParams.get("since") ?? "0", 10) || 0;
      const wait = Math.min(Number.parseInt(url.searchParams.get("wait") ?? "0", 10) || 0, 5000);

      const collect = (): Ev[] => call.events.filter((e) => e.seq > since);
      if (collect().length > 0 || wait === 0) {
        const events = collect();
        const cursor = events.length ? events[events.length - 1]!.seq : since;
        return send(200, { events, call, cursor });
      }

      let done = false;
      const waiter: Waiter = (): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        const events = collect();
        const cursor = events.length ? events[events.length - 1]!.seq : since;
        send(200, { events, call, cursor });
      };
      const timer = setTimeout(waiter, wait);
      waiters.add(waiter);
      return;
    }

    const callMatch = /^\/api\/v1\/calls\/([^/]+)$/.exec(url.pathname);
    if (req.method === "GET" && callMatch) {
      const call = calls.get(callMatch[1]!);
      if (!call) return send(404, { error: { code: "not_found", message: "unknown call" } });
      return send(200, { call });
    }

    const speakMatch = /^\/api\/v1\/calls\/([^/]+)\/speak$/.exec(url.pathname);
    if (req.method === "POST" && speakMatch) {
      const call = calls.get(speakMatch[1]!);
      if (!call) return send(404, { error: { code: "not_found", message: "unknown call" } });
      const body = JSON.parse((await readBody(req)) || "{}");
      call.state = "active";
      emit(call, "utterance.agent", { text: String(body.text ?? "") });
      return send(202, { call });
    }

    const hangupMatch = /^\/api\/v1\/calls\/([^/]+)\/hangup$/.exec(url.pathname);
    if (req.method === "POST" && hangupMatch) {
      const call = calls.get(hangupMatch[1]!);
      if (!call) return send(404, { error: { code: "not_found", message: "unknown call" } });
      emit(call, "call.ended", { reason: "hangup" });
      call.state = "ended";
      call.endedAt = new Date().toISOString();
      return send(200, { call });
    }

    send(404, { error: { code: "not_found", message: "not found" } });
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      resolve({
        baseUrl: `http://127.0.0.1:${port}`,
        calls,
        close: () =>
          new Promise((done) => {
            server.close(() => done());
          }),
      });
    });
  });
}
