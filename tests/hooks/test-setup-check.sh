#!/bin/bash
#
# Tests for plugins/flow/hooks/setup-check.sh, the SessionStart check. It
# must print nothing when the repo is set up, one line when it is not, and
# always exit 0, so it never blocks a session.
#
# HERMETIC: each case runs in a throwaway git repo (mktemp -d).
#
# Usage: bash tests/hooks/test-setup-check.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The project.md lines hold literal backticks, so single quotes are on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REAL_REPO/plugins/flow/hooks/setup-check.sh"
export CLAUDE_PLUGIN_ROOT="$REAL_REPO/plugins/flow"

TMPROOT="$(mktemp -d)" || exit 1

# check <label> <want-stdout>
check() {
    local out rc
    out="$(bash "$HOOK" </dev/null 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "$2" ]; then
        pass "$1"
    else
        fail "$1" "exit: $rc (want 0)" "output: [$out]" "want:   [$2]"
    fi
}

mkdir -p "$TMPROOT/nogit"
cd "$TMPROOT/nogit" || exit 1
check "outside a git repo -> silent" ""

REPO="$TMPROOT/repo"
git init -q "$REPO" >/dev/null 2>&1
cd "$REPO" || exit 1
check "nothing set up -> one line" \
    "flow: .claude/project.md is missing, CLAUDE.md is missing. Run /flow:setup."

project_md_write "$REPO" 'test: `make test`' 'lint: `make lint`'
printf '# Project\n' > CLAUDE.md
check "no block -> one line" "flow: the CLAUDE.md flow block is missing. Run /flow:setup."

"$CLAUDE_PLUGIN_ROOT/bin/flow-claude-block" --apply >/dev/null
check "set up -> silent" ""

sed -i.bak -E 's/^<!-- flow:begin rev [0-9]+ -->$/<!-- flow:begin rev 0 -->/' CLAUDE.md && rm -f CLAUDE.md.bak
check "old block -> one line" \
    "flow: the CLAUDE.md flow block is old (rev 0, current rev $(sed -nE '1s/^<!-- flow:begin rev ([0-9]+) -->$/\1/p' "$CLAUDE_PLUGIN_ROOT/templates/claude-block.md")). Run /flow:setup."

harness_report
