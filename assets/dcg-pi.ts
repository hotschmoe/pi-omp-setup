// pi-omp-setup: managed dcg extension
// Adapter for DCG's documented robot decision API; commands are never executed here.
import { spawnSync } from "node:child_process";

export function checkCommand(command: string, run = spawnSync): { block: true; reason: string } | undefined {
  try {
    const result = run(process.env.DCG_BIN ?? "dcg", ["--robot", "test", "--", command], {
      encoding: "utf8", timeout: 10000, maxBuffer: 1024 * 1024, windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (!result.error && result.status === 0) return;
    if (!result.error && result.status === 1) {
      let reason = "DCG blocked a destructive shell command.";
      try {
        const parsed = JSON.parse(String(result.stdout));
        if (typeof parsed.reason === "string") reason = parsed.reason;
        if (typeof parsed.rule_id === "string") reason += ` [${parsed.rule_id}]`;
      } catch { /* Exit status remains authoritative if diagnostics are malformed. */ }
      return { block: true, reason };
    }
  } catch { /* Missing binary, timeout, and process failures block this tool call. */ }
  return { block: true, reason: "DCG could not check this command. Check the dcg installation before retrying." };
}

export default function dcgPi(api: any): void {
  api.on("tool_call", (event: any) => {
    if (event.toolName !== "bash" || typeof event.input?.command !== "string") return;
    return checkCommand(event.input.command);
  });
}
