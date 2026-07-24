/**
 * control_api entry point. Loads env-driven config, builds the Fastify app,
 * and listens. Handles SIGTERM/SIGINT for clean shutdown.
 */

import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const app = await buildApp(config);

  const close = async (signal: string): Promise<void> => {
    app.log.info(`${signal} received - shutting down`);
    await app.close();
    process.exit(0);
  };

  process.on("SIGTERM", () => void close("SIGTERM"));
  process.on("SIGINT", () => void close("SIGINT"));

  try {
    await app.listen({ port: config.port, host: config.host });
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}

void main();
