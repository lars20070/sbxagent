# Dev-only mirror of the network-block escalation filter, shared by the
# sbxclaude and sbxcodex kits. This file is NOT shipped into any sandbox —
# Docker Sandbox Kits can only write declared files as the agent user
# (UID 1000; see docs.docker.com's kit-reference.md, "Setup > files"), and
# this filter has to be root-owned and outside $HOME so the agent it's
# watching can't disable it with an ordinary file edit. The copies that
# actually ship are the heredocs in each kit's "Network-block escalation
# hook" setup step, which install it to /usr/local/lib/sbxagent/.
#
# Detection is identical on both hosts: the filter reads the whole payload
# rather than named fields. Enforcement is not. Claude Code treats
# `continue: false` as a hard turn-end; Codex instead replaces the tool
# result with `stopReason` and lets the model continue, so on sbxcodex this
# is a firm notice rather than a hard stop.
#
# Edit here for readability and local testing, then copy the body below
# into both heredocs — `make lint` fails if any of them disagree.
#
# Try it locally:
#   jq -n '{tool_name:"Bash",tool_input:{command:"curl https://x"},error:"Blocked by local rule for x"}' \
#     | jq -f kits/network-block.jq

# BEGIN-SYNCED (must match every kit's spec.yaml heredoc exactly)
# Every string in the payload except the tool's own input. Field names
# differ per event (.tool_response on PostToolUse, .error on
# PostToolUseFailure), so match the whole payload rather than a field.
def haystack: [ del(.tool_input) | .. | strings ] | join("\n");

# Commands that can reach the network. Used to disqualify the
# self-reference exemption below, so a real block is never masked.
# Local git readers stay eligible; only git's network subcommands count.
def reaches_network:
  (.tool_input.command // "")
  | test("https?://"
       + "|\\b(curl|wget|nc|telnet|ssh|scp|rsync)\\b"
       + "|\\b(npm|npx|pnpm|yarn|pip|pip3|uv|uvx)\\b"
       + "|\\b(apt|apt-get|brew|gh)\\b"
       + "|\\bdocker\\s+(pull|push|run|build)\\b"
       + "|\\bgit\\s+(fetch|pull|push|clone|remote|ls-remote|submodule)\\b");

# These block strings appear verbatim in this project's own docs, spec,
# and tests, so a Bash read of one of those files must not trip the
# guard. Scoped to Bash's own command field so a blocked WebFetch URL
# that merely contains one of these filenames is never exempted.
#
# The command must also show no sign of network egress. Without that,
# `curl https://blocked # spec.yaml` would suppress a genuine block
# behind a filename mention — the exact outcome this guard exists to
# prevent. When a command both reads such a file and reaches out, fail
# safe and let the guard fire.
def self_reference:
  .tool_name == "Bash"
  and (reaches_network | not)
  and ((.tool_input.command // "")
       | test("AGENTS\\.md|CLAUDE\\.md|spec\\.yaml|network-block|toolchain_test"));

def stop($why; $tell):
  { continue: false,
    stopReason:
      ($why + " Stopping — do not retry, mirror, vendor, or otherwise work "
      + "around this. Report it to the user and wait."),
    systemMessage: $tell };

haystack as $out
| if self_reference
    or ($out | test("Blocked by (network policy|local rule for|org policy)") | not)
  then
    {}

  # Centralised org policy. Deliberately does not suggest
  # `sbx policy allow`: the user cannot lift this one themselves.
  elif $out | test("Blocked by org policy") then
    stop("A network request was blocked by your organisation's policy.";
         "Blocked by org policy.\n"
         + "Your company policy is blocking this request — contact IT if you need access.")

  else
    # A local deny and a default-deny need opposite remedies: deny rules take
    # precedence over allow rules, so `sbx policy allow` cannot lift a local
    # deny — the rule itself has to be removed. Capture the two separately
    # instead of collapsing them into one host with one piece of advice.
    #
    # `capture` yields nothing when it does not match, and `empty // empty` is
    # still empty — that would bind no variable and emit no output at all, i.e.
    # fail open. `// null` guarantees exactly one value.
    ( ($out | capture("Blocked by local rule for (?<h>[^\\s]+)").h) // null
    ) as $denied
    | ( ($out | capture("Blocked by network policy: domain (?<h>[^\\s]+)").h) // null
      ) as $host
    | if $denied != null then
        stop("A local deny rule blocks \($denied); `sbx policy allow` cannot override it.";
             "Blocked host: \($denied) — by a local deny rule.\n"
             + "Deny beats allow, so allowing it will not help. Find and remove the rule:\n"
             + "  sbx policy ls --wide\n"
             + "  sbx policy rm network --resource \"\($denied)\"                      # global\n"
             + "  sbx policy rm network --sandbox <sandbox> --resource \"\($denied)\"  # one sandbox")
      elif $host != null then
        stop("The sandbox network policy blocked \($host).";
             "Blocked host: \($host)\n"
             + "Run on your host:  sbx policy allow network \"\($host)\"")
      else
        stop("A network request was blocked by the sandbox network policy.";
             "A network request was blocked by the sandbox network policy.\n"
             + "See the tool output above for the host, then allow it with:\n"
             + "  sbx policy allow network \"<host>\"")
      end
  end
# END-SYNCED
