import { spawn } from "child_process";
import { resolve } from "path";

export interface OpenCodeCallOptions {
  prompt: string;
  model?: string;
  cwd?: string;
}

export async function callOpenCode(options: OpenCodeCallOptions): Promise<string> {
  const cwd = options.cwd || process.cwd();
  return new Promise((resolveResult, reject) => {
    const args = ["--print", options.prompt];
    if (options.model) {
      args.push("--model", options.model);
    }
    const proc = spawn("opencode", args, { cwd });
    let output = "";
    let error = "";
    proc.stdout.on("data", (d) => (output += d.toString()));
    proc.stderr.on("data", (d) => (error += d.toString()));
    proc.on("close", (code) => {
      if (code === 0) resolveResult(output.trim());
      else reject(new Error(`opencode exited ${code}: ${error}`));
    });
    proc.on("error", reject);
  });
}
