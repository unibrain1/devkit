#!/bin/bash
#
# Regression test for plugins/flow/hooks/guard-private-paths.sh: a forced
# `git add` of a path in the `private_paths` key is denied; everything else
# passes. Without the key, or without project.md, the hook allows everything.
#
# HERMETIC: runs the hook inside a throwaway git repo (mktemp -d) with its own
# .claude/project.md.
#
# Usage: bash tests/hooks/test-guard-private-paths.sh
# Exit code: 0 if all cases pass, 1 otherwise.

# The project.md lines hold literal backticks, so single quotes are on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN_ROOT="$REAL_REPO/plugins/flow"
HOOK="$PLUGIN_ROOT/hooks/guard-private-paths.sh"
if [ ! -x "$HOOK" ]; then
    echo "FAIL: $HOOK not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1
REPO="$TMPROOT/repo"
git init -q "$REPO" >/dev/null 2>&1
cd "$REPO" || exit 1
project_md_write "$REPO" 'private_paths: `docs/plans _noupload`'

# run_hook <command>: prints the permission decision, or "allow" when the hook
# prints nothing. The hook runs with CLAUDE_PLUGIN_ROOT as set by the caller.
run_hook() {
    local out
    out="$(jq -nc --arg c "$1" '{tool_input:{command:$c}}' | bash "$HOOK")"
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

# check <expected> <command>
check() {
    local expected="$1" cmd="$2" got
    got="$(run_hook "$cmd")"
    got="${got:-allow}"
    if [ "$got" = "$expected" ]; then
        pass "$expected  $cmd"
    else
        fail "expected $expected, got $got  $cmd"
    fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

check deny  'git add -f docs/plans/issues/x.md'
check deny  'git add --force _noupload/audit-reports/a.md'
check deny  'git add -Af ./docs/plans'
check deny  'cd x && git -C . add -f docs/plans/a'
check allow 'git add docs/plans/x.md'
check allow 'git add -f scripts/x.sh'
check allow 'git add -f scripts/x.sh && cat docs/plans/README.md'
check allow 'git commit -m "mention git add -f docs/plans"'
check allow 'git status'
check allow 'git add -f docs/plansible.md'

# The deny reason names the configured paths.
reason="$(jq -nc --arg c 'git add -f _noupload/a' '{tool_input:{command:$c}}' | bash "$HOOK" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason')"
if [[ "$reason" == *"docs/plans _noupload"* ]]; then
    pass "the deny reason names the private paths"
else
    fail "the deny reason names the private paths" "reason: [$reason]"
fi

# A different list in project.md changes what the hook blocks.
project_md_write "$REPO" 'private_paths: `notes/ secret.d`'
check deny  'git add -f notes/a.md'
check deny  'git add -f secret.d/key'
check allow 'git add -f docs/plans/x.md'

# Without CLAUDE_PLUGIN_ROOT, the hook finds flow-project-fact from its own path.
unset CLAUDE_PLUGIN_ROOT
check deny  'git add -f notes/a.md'
check allow 'git add -f docs/plans/x.md'

# No private_paths key: allow, with no output.
project_md_write "$REPO" 'test: `make test`'
OUT_NOKEY="$(jq -nc --arg c 'git add -f docs/plans/x.md' '{tool_input:{command:$c}}' | bash "$HOOK")"
RC_NOKEY=$?
if [ "$RC_NOKEY" -eq 0 ] && [ -z "$OUT_NOKEY" ]; then
    pass "no private_paths key: allow, exit 0, no output"
else
    fail "no private_paths key: allow, exit 0, no output" "exit: $RC_NOKEY" "output: [$OUT_NOKEY]"
fi

# No project.md: allow, with no output.
rm -f "$REPO/.claude/project.md"
OUT_NOFILE="$(jq -nc --arg c 'git add -f docs/plans/x.md' '{tool_input:{command:$c}}' | bash "$HOOK")"
RC_NOFILE=$?
if [ "$RC_NOFILE" -eq 0 ] && [ -z "$OUT_NOFILE" ]; then
    pass "no project.md: allow, exit 0, no output"
else
    fail "no project.md: allow, exit 0, no output" "exit: $RC_NOFILE" "output: [$OUT_NOFILE]"
fi

# hooks.json is valid and registers the hook on the Bash matcher.
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("${CLAUDE_PLUGIN_ROOT}/hooks/guard-private-paths.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
    pass "hooks.json registers guard-private-paths.sh as a PreToolUse hook on Bash"
else
    fail "hooks.json registers guard-private-paths.sh as a PreToolUse hook on Bash"
fi

harness_report
