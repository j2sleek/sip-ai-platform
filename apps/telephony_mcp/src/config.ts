/**
 * Environment-driven configuration for the telephony MCP server.
 * Safe development defaults; no secrets are committed (see AGENTS.md).
 */

export interface TelephonyConfig {
  /** Base URL of the control_api HTTP surface. */
  controlApiUrl: string;
  /** Optional bearer token for control_api (empty = auth disabled). */
  controlToken: string;
  /** Per-request timeout for control_api calls, in ms. */
  requestTimeoutMs: number;
  /** Default long-poll budget for wait_for_input, in ms. */
  defaultWaitMs: number;
  /** Hard cap for wait_for_input, in ms. */
  maxWaitMs: number;
}

function parsePositiveInt(value: string | undefined, fallback: number): number {
  if (value === undefined || value === "") return fallback;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`expected a positive integer, got ${JSON.stringify(value)}`);
  }
  return parsed;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): TelephonyConfig {
  const requestTimeoutMs = parsePositiveInt(env.REQUEST_TIMEOUT_MS, 15_000);
  return {
    controlApiUrl: (env.CONTROL_API_URL ?? "http://127.0.0.1:4000").replace(/\/+$/, ""),
    controlToken: env.CONTROL_API_TOKEN ?? "",
    requestTimeoutMs,
    defaultWaitMs: parsePositiveInt(env.DEFAULT_WAIT_MS, 25_000),
    maxWaitMs: parsePositiveInt(env.MAX_WAIT_MS, 30_000),
  };
}
