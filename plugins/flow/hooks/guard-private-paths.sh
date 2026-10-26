#!/bin/bash
#
# PreToolUse hook (Bash matcher): blocks a forced `git add` of a private path.
# The paths come from the `private_paths` key of .claude/project.md. They are
# gitignored because the repository can be public and they hold private
# working notes (plans, spike captures, audit reports). .gitignore stops a
# plain `git add`, but `git add -f` / `--force` bypasses it, and nothing else
# stopped that.
#
# There is no override: these paths are never committed. Move the content to
# a committed location first if it must be public.
#
# If project.md is missing, or it has no `private_paths` key, the repo has no
# private paths and the hook allows the command (exit 0, no output).
#
set -uo pipefail

plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Any failure of the lookup means "no private paths": allow.
if ! private_value="$("${plugin_root}/bin/flow-project-fact" private_paths 2>/dev/null)"; then
  exit 0
fi

read -r -a private_paths <<< "$private_value"
[ "${#private_paths[@]}" -gt 0 ] || exit 0

input="$(cat)"

if ! cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"guard-private-paths.sh could not parse hook input. jq may be missing — install it. Denying by default."}}'
  exit 0
fi

# Build one regex alternation of the paths. Regex characters are escaped and
# a trailing slash is removed.
alternation=""
for p in "${private_paths[@]}"; do
  p="${p%/}"
  [ -n "$p" ] || continue
  escaped="$(printf '%s' "$p" | sed 's/[][\\.*^$+?(){}|]/\\&/g')"
  alternation="${alternation:+${alternation}|}${escaped}"
done
[ -n "$alternation" ] || exit 0

# Look at each `git add` segment of a compound command on its own, so a
# flag in one command cannot pair with a path in another.
while IFS= read -r seg; do
  # The segment must BE a git add (optionally after VAR=value prefixes or
  # `git -C dir`), not merely mention one inside a quoted message.
  echo "$seg" | grep -qE '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+add\b' || continue
  echo "$seg" | grep -qE '(^|[[:space:]])(-[a-zA-Z]*f[a-zA-Z]*|--force)([[:space:]]|$)' || continue
  if echo "$seg" | grep -qE "(^|[[:space:]\"'/])(\./)?(${alternation})(/|[[:space:]\"']|\$)"; then
    reason="Forced git add of a private path (${private_paths[*]}) is blocked. These paths hold private notes and are never committed."
    jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
  fi
done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;|\|)/\n/g')

exit 0
