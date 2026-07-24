/**
 * Environment-driven configuration for control_api.
 * Safe development defaults; no secrets.
 */

export type LogLevel = "debug" | "info" | "warn" | "error";

export interface Config {
  appEnv: string;
  port: number;
  host: string;
  logLevel: LogLevel;
}

const VALID_LOG_LEVELS: readonly LogLevel[] = ["debug", "info", "warn", "error"];

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

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    appEnv: env.APP_ENV ?? "development",
    port: Number.parseInt(env.PORT ?? "4000", 10),
    host: env.HOST ?? "0.0.0.0",
    logLevel: parseLogLevel(env.LOG_LEVEL),
  };
}
