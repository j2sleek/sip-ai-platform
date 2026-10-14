/**
 * Environment-driven configuration for control_api.
 * Safe development defaults; no secrets are committed (see AGENTS.md).
 */

export type LogLevel = "debug" | "info" | "warn" | "error";

/** Which backend executes call control (originate/hangup/speak). */
export type CallBackendKind = "simulated" | "ari";

export interface AriConfig {
  /** Base URL of the Asterisk ARI HTTP interface, e.g. http://127.0.0.1:8088 */
  baseUrl: string;
  username: string;
  password: string;
  /** Stasis application name registered in Asterisk. */
  app: string;
  /** Per-request timeout in ms. */
  timeoutMs: number;
  /** Endpoint template for originate; `{to}` is replaced by the destination. */
  endpointTemplate: string;
  /**
   * Caller ID presented on outbound calls when the request omits `from`
   * (e.g. `"AI Assistant" <2000>`). Without this, ARI defaults the channel
   * caller ID to "Anonymous", which is what the callee sees.
   */
  callerId: string;
}

export interface Config {
  appEnv: string;
  port: number;
  host: string;
  logLevel: LogLevel;
  /** Backend used to execute call control. */
  callBackend: CallBackendKind;
  /** Optional bearer token guarding /api/v1/*. Empty = auth disabled. */
  controlToken: string;
  ari: AriConfig;
  /** Long-poll upper bound for GET /api/v1/calls/:id/events. */
  maxEventWaitMs: number;
  /** Maximum events retained per call. */
  maxEventsPerCall: number;
}

const VALID_LOG_LEVELS: readonly LogLevel[] = ["debug", "info", "warn", "error"];
const VALID_BACKENDS: readonly CallBackendKind[] = ["simulated", "ari"];

function parseLogLevel(value: string | undefined): LogLevel {
  const level = (value ?? "info").toLowerCase();
  const normalized = level === "warning" ? "warn" : level;
  if ((VALID_LOG_LEVELS as string[]).includes(normalized)) {
    return normalized as LogLevel;
  }
  throw new Error(
    `invalid LOG_LEVEL: ${JSON.stringify(value)} (use debug|info|warn|error)`,
  );
}

function parseBackend(value: string | undefined): CallBackendKind {
  const backend = (value ?? "ari").toLowerCase();
  if ((VALID_BACKENDS as string[]).includes(backend)) {
    return backend as CallBackendKind;
  }
  throw new Error(
    `invalid CALL_BACKEND: ${JSON.stringify(value)} (use simulated|ari)`,
  );
}

function parsePositiveInt(value: string | undefined, fallback: number): number {
  if (value === undefined || value === "") return fallback;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`expected a positive integer, got ${JSON.stringify(value)}`);
  }
  return parsed;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    appEnv: env.APP_ENV ?? "development",
    port: Number.parseInt(env.PORT ?? "4000", 10),
    host: env.HOST ?? "0.0.0.0",
    logLevel: parseLogLevel(env.LOG_LEVEL),
    callBackend: parseBackend(env.CALL_BACKEND),
    controlToken: env.CONTROL_API_TOKEN ?? "",
    ari: {
      baseUrl: (env.ARI_BASE_URL ?? "http://127.0.0.1:8088").replace(/\/+$/, ""),
      username: env.ARI_USERNAME ?? "voice_core",
      password: env.ARI_PASSWORD ?? "",
      app: env.ARI_APP ?? "voice_core",
      timeoutMs: parsePositiveInt(env.ARI_TIMEOUT_MS, 10_000),
      endpointTemplate: env.ARI_ENDPOINT_TEMPLATE ?? "PJSIP/{to}",
      callerId: env.ARI_CALLER_ID ?? '"AI Assistant" <2000>',
    },
    maxEventWaitMs: parsePositiveInt(env.MAX_EVENT_WAIT_MS, 30_000),
    maxEventsPerCall: parsePositiveInt(env.MAX_EVENTS_PER_CALL, 1_000),
  };
}
