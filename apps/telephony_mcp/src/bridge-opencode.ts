import { spawn } from "child_process";
import { join } from "path";

export interface OpenCodeOptions {
  message: string;
  sessionId?: string;
  model?: string;
  agent?: string;
  cwd?: string;
  format?: "default" | "json";
}

export async function callOpenCode(options: OpenCodeOptions): Promise<string> {
  const cwd = options.cwd || process.cwd();
  return new Promise((resolve, reject) => {
    const args = ["run"];
    if (options.sessionId) {
      args.push("--session", options.sessionId);
    } else if (options.agent) {
      args.push("--agent", options.agent);
    }
    if (options.model) {
      args.push("--model", options.model);
    }
    if (options.format) {
      args.push("--format", options.format);
    }
    args.push(options.message);
    const proc = spawn("opencode", args, { cwd });
    let out = "";
    let err = "";
    proc.stdout.on("data", (d) => (out += d.toString()));
    proc.stderr.on("data", (d) => (err += d.toString()));
    proc.on("close", (code) => {
      if (code === 0) resolve(out.trim());
      else reject(new Error(`opencode exited ${code}: ${err}`));
    });
    proc.on("error", reject);
  });
}

export async function callOpenCodeJson(options: OpenCodeOptions): Promise<any> {
  const res = await callOpenCode({ ...options, format: "json" });
  try {
    return JSON.parse(res);
  } catch {
    return res;
  }
}
