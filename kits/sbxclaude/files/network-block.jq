# Dev-only mirror of the network-block escalation filter. This file is NOT
# shipped into the sandbox — Docker Sandbox Kits can only write declared
# files as the agent user (UID 1000; see docs.docker.com's kit-reference.md,
# "Setup > files"), and this filter has to be root-owned and outside $HOME
# so the agent it's watching can't disable it with an ordinary file edit.
# The copy that actually ships is the heredoc in kits/sbxclaude/spec.yaml's
# "Network-block escalation hook" setup step.
#
# Edit here for readability and local testing, then copy the body below
# into that heredoc (or vice versa) — `make lint` fails if the two disagree.
#
# Try it locally:
#   jq -n '{tool_name:"Bash",tool_input:{command:"curl https://x"},error:"Blocked by local rule for x"}' \
#     | jq -f kits/sbxclaude/files/network-block.jq

# BEGIN-SYNCED (must match kits/sbxclaude/spec.yaml's heredoc exactly)
# Every string in the payload except the tool's own input. Field names
# differ per event (.tool_response on PostToolUse, .error on
# PostToolUseFailure), so match the whole payload rather than a field.
def haystack: [ del(.tool_input) | .. | strings ] | join("\n");

# These block strings appear verbatim in this project's own docs, spec,
# and tests, so a Bash read of one of those files must not trip the
# guard. Scoped to Bash's own command field so a blocked WebFetch URL
# that merely contains one of these filenames is never exempted.
def self_reference:
  .tool_name == "Bash"
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
    # `capture` yields nothing when it does not match, and
    # `empty // empty` is still empty — that would bind no $host and
    # emit no output at all, i.e. fail open. `// null` guarantees
    # exactly one value.
    ( ($out | capture("Blocked by network policy: domain (?<h>[^\\s]+)").h)
      // ($out | capture("Blocked by local rule for (?<h>[^\\s]+)").h)
      // null
    ) as $host
    | if $host == null then
        stop("A network request was blocked by the sandbox network policy.";
             "A network request was blocked by the sandbox network policy.\n"
             + "See the tool output above for the host, then allow it with:\n"
             + "  sbx policy allow network \"<host>\"")
      else
        stop("The sandbox network policy blocked \($host).";
             "Blocked host: \($host)\n"
             + "Run on your host:  sbx policy allow network \"\($host)\"")
      end
  end
# END-SYNCED
