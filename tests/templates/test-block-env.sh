#!/bin/bash
#
# Tests for the .env block hook of the web-app template:
# plugins/flow/templates/web-app/.claude/hooks/block-env.sh.
#
# The hook reads the PreToolUse JSON on stdin and reads .tool_input.file_path.
# It must exit 2, with "BLOCK:" on stderr, for a file named .env or .env.<name>
# in any folder. It must exit 0, with no stderr, for a name that ends in
# .example or .sample, for each other file, and for input with no file path.
# It must exit 2 when the input is empty or not JSON, and when jq is not on
# PATH. It matches the name in any letter case.
#
# The test runs the hook with "bash <script>", as the settings.json command
# does, not by its path.
#
# Each case has a break-it control where a control can break it. The control
# copies the hook, breaks one line, runs this script on the copy, and expects
# the named case to fail. Set BLOCK_ENV_NO_CONTROLS=1 to skip them.
#
# Env overrides, for the controls on a scratch copy:
#   BLOCK_ENV_SCRIPT  the hook script
#
# Usage: bash tests/templates/test-block-env.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# SC2016: the control mutations are single-quoted on purpose. eval expands
# them inside the control.
# shellcheck disable=SC2016

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BLOCK_ENV_SCRIPT="${BLOCK_ENV_SCRIPT:-$REAL_REPO/plugins/flow/templates/web-app/.claude/hooks/block-env.sh}"
BASH_BIN="$(command -v bash)"

TMPROOT="$(mktemp -d)" || exit 1

if command -v jq >/dev/null 2>&1; then
    pass "jq is available"
else
    fail "jq is available" "install jq"
    harness_report
fi

if [ -f "$BLOCK_ENV_SCRIPT" ]; then
    pass "the hook script exists"
else
    fail "the hook script exists" "missing: $BLOCK_ENV_SCRIPT"
    harness_report
fi

# run_hook <stdin text> [PATH value]: runs the hook. Sets RC and ERR (stderr).
run_hook() {
    local input="$1" path="${2:-$PATH}"
    ERR="$(printf '%s' "$input" | PATH="$path" "$BASH_BIN" "$BLOCK_ENV_SCRIPT" 2>&1 >/dev/null)"
    RC=$?
}

# expect_block <label> <stdin text> [PATH value]
expect_block() {
    run_hook "$2" "${3:-$PATH}"
    if [ "$RC" -eq 2 ] && printf '%s\n' "$ERR" | grep -q '^BLOCK:'; then
        pass "$1"
    else
        fail "$1" "exit: $RC" "stderr: $ERR"
    fi
}

# expect_allow <label> <stdin text>
expect_allow() {
    run_hook "$2"
    if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then
        pass "$1"
    else
        fail "$1" "exit: $RC" "stderr: $ERR"
    fi
}

# hook_json <tool> <file path>: a PreToolUse input for one tool call.
hook_json() {
    jq -cn --arg t "$1" --arg f "$2" '{hook_event_name: "PreToolUse", tool_name: $t, tool_input: {file_path: $f}}'
}

# --- blocked -----------------------------------------------------------
expect_block "blocks Read of .env" "$(hook_json Read .env)"
expect_block "blocks Edit of .env.local" "$(hook_json Edit .env.local)"
expect_block "blocks Write of app/.env.production" "$(hook_json Write app/.env.production)"
expect_block "blocks Read of /srv/app/.env" "$(hook_json Read /srv/app/.env)"
expect_block "blocks Read of .ENV" "$(hook_json Read .ENV)"
expect_block "blocks Edit of config/.Env.local" "$(hook_json Edit config/.Env.local)"
expect_block "blocks Grep with path .env" '{"tool_name":"Grep","tool_input":{"pattern":".","path":".env"}}'
expect_block "blocks NotebookEdit of a/.env" '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"a/.env"}}'
expect_block "blocks input that is not JSON" "this is not json"
expect_block "blocks empty input" ""
expect_block "blocks blank input" "   "

# --- allowed -----------------------------------------------------------
expect_allow "allows .env.example" "$(hook_json Read .env.example)"
expect_allow "allows config/.env.sample" "$(hook_json Edit config/.env.sample)"
expect_allow "allows .ENV.Example" "$(hook_json Read .ENV.Example)"
expect_allow "allows Grep with path src" '{"tool_name":"Grep","tool_input":{"pattern":".","path":"src"}}'
expect_allow "allows README.md" "$(hook_json Read README.md)"
expect_allow "allows env.ts" "$(hook_json Write env.ts)"
expect_allow "allows .envrc" "$(hook_json Read .envrc)"
expect_allow "allows input with no tool_input" "{}"
expect_allow "allows input with no file_path" '{"tool_input":{}}'

# --- jq not on PATH ----------------------------------------------------
# An empty bin folder. The hook calls no tool except jq: command, echo,
# shopt, and the ${file##*/} expansion are bash builtins.
NOJQ_BIN="$TMPROOT/nojq-bin"
mkdir -p "$NOJQ_BIN"
if PATH="$NOJQ_BIN" command -v jq >/dev/null 2>&1; then
    fail "blocks when jq is not on PATH" "jq is still on the scratch PATH"
else
    run_hook "$(hook_json Read README.md)" "$NOJQ_BIN"
    if [ "$RC" -eq 2 ] && printf '%s\n' "$ERR" | grep -q '^BLOCK:.*jq'; then
        pass "blocks when jq is not on PATH"
    else
        fail "blocks when jq is not on PATH" "exit: $RC" "stderr: $ERR"
    fi
fi

# --- break-it controls -------------------------------------------------
# control <name> <expected-failing-case> <sed -E expression>
# The control copies the hook, applies the sed expression to the copy, runs
# this script on the copy, and expects "FAIL: <expected-failing-case>".
control() {
    local name="$1" expect="$2" expr="$3" copy out rc
    copy="$TMPROOT/control-$name.sh"
    sed -E -e "$expr" "$BLOCK_ENV_SCRIPT" > "$copy"
    if cmp -s "$copy" "$BLOCK_ENV_SCRIPT"; then
        fail "control $name: the mutation changed the hook" "sed expression: $expr"
        return
    fi
    out="$(BLOCK_ENV_NO_CONTROLS=1 BLOCK_ENV_SCRIPT="$copy" bash "$SELF" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF -- "FAIL: $expect"; then
        pass "control $name: case failed as expected ($expect)"
    else
        fail "control $name: case did not fail as expected" "expected: FAIL: $expect" \
            "exit: $rc" "$(printf '%s\n' "$out" | grep -E '^(FAIL|[0-9]+ scenario)' | head -4 | tr '\n' ' ')"
    fi
}

if [ "${BLOCK_ENV_NO_CONTROLS:-}" != "1" ]; then
    control no-env-star "blocks Edit of .env.local" \
        's/^([[:space:]]*\.env) \| \.env\.\*\)/\1)/'
    control no-example-line "allows .env.example" \
        '/^[[:space:]]*\*\.example \| \*\.sample\) exit 0 ;;$/d'
    control env-prefix-glob "allows .envrc" \
        's/^([[:space:]]*)\.env \| \.env\.\*\)/\1.env*)/'
    control full-path-match "blocks Read of /srv/app/.env" \
        's/^case "\$\{file##\*\/\}" in$/case "$file" in/'
    control no-nocasematch "blocks Read of .ENV" \
        '/^shopt -s nocasematch$/d'
    control empty-input-allowed "blocks empty input" \
        "s/jq -nr 'input \\| \\.tool_input/jq -r '.tool_input/"
    control no-grep-path "blocks Grep with path .env" \
        's/ \/\/ \.path \/\/ empty/ \/\/ empty/'
    control no-notebook-path "blocks NotebookEdit of a/.env" \
        's/ \/\/ \.notebook_path \/\/ / \/\/ /'
    control block-exit-code "blocks Read of .env" \
        '/They hold secrets/,/;;/ s/exit 2/exit 0/'
    control not-json-allowed "blocks input that is not JSON" \
        '/cannot read the hook input as JSON/,/fi/ s/exit 2/exit 0/'
    control no-jq-allowed "blocks when jq is not on PATH" \
        '/needs jq to read the file path/,/fi/ s/exit 2/exit 0/'
    control empty-path-blocked "allows input with no file_path" \
        's/^\[ -n "\$file" \] \|\| exit 0$/[ -n "$file" ] || { echo "BLOCK: no path" >\&2; exit 2; }/'
fi

harness_report
