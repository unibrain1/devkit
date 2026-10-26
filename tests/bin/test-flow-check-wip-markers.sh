#!/bin/bash
#
# Regression test for plugins/flow/bin/flow-check-wip-markers.
#
# finish-milestone.md Step 6 and review-milestone.md Step 1 both need this
# script's exit code and match list to agree exactly with what
# `grep -n "WIP:" <release notes file>` would show — this test pins the
# three cases those callers branch on: clean notes, a remaining marker, and
# a missing file. It also pins the project.md key guard.
#
# HERMETIC: builds a throwaway git repo (mktemp -d) with its own
# .claude/project.md and release notes file.
#
# Usage: bash tests/bin/test-flow-check-wip-markers.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The project.md lines hold literal backticks, so single quotes are on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-check-wip-markers"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1

REPO="$TMPROOT/repo"
git init -q "$REPO" >/dev/null 2>&1
cd "$REPO" || exit 1
project_md_write "$REPO" 'release_notes: `notes/RN-{version}.md`'
mkdir -p notes
NOTES_FILE="notes/RN-v9.9.9.md"

assert() {
    local desc="$1" expected_exit="$2" actual_exit="$3"
    if [ "$expected_exit" -eq "$actual_exit" ]; then
        pass "$desc"
    else
        fail "$desc" "expected exit $expected_exit, got $actual_exit"
    fi
}

# --- Scenario 1: file missing -> exit 2 -------------------------------------
rm -f "$NOTES_FILE"
"$SCRIPT" v9.9.9 >/dev/null 2>&1
assert "missing release notes file exits 2" 2 "$?"

# --- Scenario 2: clean notes, no WIP markers -> exit 0 ----------------------
cat > "$NOTES_FILE" <<'NOTES'
## Issues Resolved

- [#1](https://github.com/example-org/example-repo/issues/1) — Done thing
NOTES
"$SCRIPT" v9.9.9 >/dev/null 2>&1
assert "clean release notes exits 0" 0 "$?"

# --- Scenario 3: one remaining WIP marker -> exit 1, printed ----------------
cat > "$NOTES_FILE" <<'NOTES'
## Issues Resolved

- WIP: [#2](https://github.com/example-org/example-repo/issues/2) — Not done yet
NOTES
OUTPUT="$("$SCRIPT" v9.9.9 2>/dev/null)"
EXIT_CODE=$?
assert "remaining WIP marker exits 1" 1 "$EXIT_CODE"

if echo "$OUTPUT" | grep -q "WIP:"; then
    pass "remaining WIP marker is printed to stdout"
else
    fail "remaining WIP marker is printed to stdout" "output: [$OUTPUT]"
fi

# --- Scenario 4: no release_notes key -> exit 10, one line on stderr ---------
project_md_write "$REPO" 'test: `make test`'
ERR4="$("$SCRIPT" v9.9.9 2>&1 >/dev/null)"
STATUS4=$?
assert "no release_notes key exits 10" 10 "$STATUS4"
if [ "$ERR4" = "flow-check-wip-markers: no 'release_notes' key in .claude/project.md. Step skipped." ]; then
    pass "no release_notes key prints one line on stderr"
else
    fail "no release_notes key prints one line on stderr" "stderr: [$ERR4]"
fi

# --- Scenario 5: no project.md -> exit 2 ------------------------------------
rm -f .claude/project.md
"$SCRIPT" v9.9.9 >/dev/null 2>&1
assert "missing project.md exits 2" 2 "$?"

harness_report
