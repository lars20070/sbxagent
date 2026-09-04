// Dev-only mirror of the network-block guard extension, used by the sbxpi
// kit. This file is NOT shipped into any sandbox — Docker Sandbox Kits can
// only write declared files as the agent user (UID 1000; see
// docs.docker.com's kit-reference.md, "Setup > files"), and this extension
// has to be root-owned and outside $HOME so the agent it's watching can't
// unregister it with an ordinary file edit. The copy that actually ships is
// the heredoc in kits/sbxpi/spec.yaml's "Network-block escalation guard"
// setup step, which installs it to /usr/local/lib/sbxagent/.
//
// The policy itself is not here — it lives in network-block.jq, which this
// file shells out to. All this adapts is Pi's extension events into the
// payload that filter already expects, and the filter's verdict back onto
// Pi's return types.
//
// Edit here, then copy the body below into the heredoc — `make lint` fails
// if the two disagree, and type-strips this file with esbuild so a syntax
// error cannot reach a sandbox. Note that esbuild checks syntax only: it
// does not resolve the `import type` above or check types.
//
// Only sbxpi ships this today; the `make lint` loop covers any kit that
// grows an EXTENSION heredoc later.

// BEGIN-SYNCED (must match every kit's spec.yaml heredoc exactly)
/**
 * Network-block escalation guard.
 *
 * Pi has no managed-settings tier the way Claude Code does, so this file is
 * root-owned and lives outside $HOME: the agent it watches cannot disable it
 * with an ordinary file edit. The policy itself is not restated here — the
 * verdict comes from network-block.jq, the same filter sbxclaude and
 * sbxcodex run, so there is exactly one place to change what counts as a
 * block and `make lint` keeps every copy of it in sync.
 *
 * Two phases, because a tool_result handler cannot end a run: it may only
 * patch content, details, isError and usage.
 *   1. tool_result — replace the blocked tool's output with the remedy.
 *   2. tool_call   — refuse every later call and terminate the run.
 * The net effect matches sbxclaude's hard stop, one beat later.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";

const FILTER = "/usr/local/lib/sbxagent/network-block.jq";

// Every stop path in the filter requires this literal, so it is a safe
// necessary condition — used only to avoid spawning jq on output that cannot
// be a block. Deliberately broader than the policy; jq still decides.
const MAYBE_BLOCKED = "Blocked by ";

function textOf(content: unknown): string {
  if (!Array.isArray(content)) return "";
  return content
    .map((block: any) =>
      block && typeof block.text === "string" ? block.text : "")
    .join("\n");
}

/** The filter's verdict for one tool result, or null to allow it through. */
function verdict(event: any): string | null {
  // Only bash reaches the network, which mirrors the "Bash|WebFetch" hook
  // matcher on sbxclaude. The scoping is load-bearing: the filter exempts a
  // *Bash* read of this repo's own docs, so routing Pi's `read` tool through
  // it would turn an ordinary read of AGENTS.md into a false block.
  if (event?.toolName !== "bash") return null;

  const response = {
    output: textOf(event.content),
    details: event.details ?? null,
    isError: event.isError === true,
  };

  let haystack: string;
  try {
    haystack = JSON.stringify(response);
  } catch {
    return null;
  }
  if (!haystack.includes(MAYBE_BLOCKED)) return null;

  // tool_name and tool_input are the field names network-block.jq already
  // expects. "Bash" carries a capital B to match its self-reference
  // exemption, which is scoped to that exact tool name.
  const payload = JSON.stringify({
    tool_name: "Bash",
    tool_input: { command: String(event?.input?.command ?? "") },
    tool_response: response,
  });

  const jq = spawnSync("jq", ["-f", FILTER], {
    input: payload,
    encoding: "utf8",
    timeout: 5000,
  });
  // Fail open if the toolchain is broken. A guard that blocked every command
  // whenever jq went missing would do more damage than the escape it stops.
  if (jq.status !== 0 || !jq.stdout) return null;

  let parsed: any;
  try {
    parsed = JSON.parse(jq.stdout);
  } catch {
    return null;
  }
  if (!parsed || parsed.continue !== false) return null;

  // stopReason instructs the model, systemMessage carries the remedy. Pi has
  // one channel here, so the model gets both.
  return [parsed.stopReason, parsed.systemMessage]
    .filter(Boolean)
    .join("\n\n");
}

export default function (pi: ExtensionAPI) {
  let blocked: string | null = null;

  // Reset per agent run, not per turn. `turn_start` fires again for every
  // LLM response *within* one user prompt, so clearing there would release
  // the exact follow-up call this guard exists to stop. Never clearing would
  // strand the session, still blocked after the user has fixed the policy.
  pi.on("agent_start", () => {
    blocked = null;
  });

  pi.on("tool_result", (event: any) => {
    if (blocked) return;
    const stop = verdict(event);
    if (!stop) return;
    blocked = stop;
    return { content: [{ type: "text", text: stop }], isError: true };
  });

  pi.on("tool_call", () => {
    if (!blocked) return;
    return { block: true, reason: blocked, terminate: true };
  });
}
// END-SYNCED
