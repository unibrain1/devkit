#!/bin/bash
#
# Tests for plugins/flow/bin/flow-project-check: a typo in a key name must
# fail loudly, because an absent optional key skips its step.
#
# HERMETIC: each case runs in a throwaway git repo (mktemp -d) with its own
# .claude/project.md.
#
# Usage: bash tests/bin/test-flow-project-check.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The project.md lines hold literal backticks, so single quotes are on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-project-check"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1
REPO="$TMPROOT/repo"
git init -q "$REPO" >/dev/null 2>&1
cd "$REPO" || exit 1

# check <label> <want-exit> <want-stderr-substring or "">
check() {
    local label="$1" want_exit="$2" want_err="$3" err status
    err="$("$SCRIPT" 2>&1 >/dev/null)"
    status=$?
    if [ "$status" -eq "$want_exit" ] && { [ -z "$want_err" ] || [[ "$err" == *"$want_err"* ]]; }; then
        pass "$label"
    else
        fail "$label" "exit: $status (want $want_exit)" "stderr: [$err]"
    fi
}

check "no project.md exits 2" 2 "is missing. Create it."

project_md_write "$REPO" 'test: `make test`' 'lint: `make lint`'
check "only necessary keys exits 0" 0 ""

project_md_write "$REPO" 'test: `t`' 'test_quick: `q`' 'lint: `l`' 'format: `f`' 'verify: `v`' \
    'deploy: see docs/DEPLOY.md' 'standards: `a b`' 'plans: `p`' \
    'release_notes: `r/{version}.md`' 'ledger: `l.md`' 'private_paths: `p x`' \
    'milestone_setup: `s`' 'issue_checks: `i`' 'milestone_checks: `m`' \
    'release_checks: `r`' 'vault: `Projects/X/X.md`'
check "every known key exits 0" 0 ""

project_md_write "$REPO" 'test: `t`' 'lint: `l`' 'release_check: `x`'
check "typo release_check exits 1" 1 "unknown key 'release_check'"
check "typo names the nearest key" 1 "Did you mean 'release_checks'?"

project_md_write "$REPO" 'test: `t`' 'lint: `l`' 'privat_paths: `x`'
check "typo privat_paths names private_paths" 1 "Did you mean 'private_paths'?"

project_md_write "$REPO" 'test: `t`'
check "missing lint exits 1" 1 "necessary key 'lint' is missing"

project_md_write "$REPO" 'lint: `l`' 'tests: `t`'
check "tests instead of test: unknown key" 1 "unknown key 'tests'"
check "tests instead of test: test is missing" 1 "necessary key 'test' is missing"

# Headings and prose lines are not keys.
printf '# Facts\n\nSome text: not a key.\n- test: `t`\n- lint: `l`\n' > .claude/project.md
check "prose lines are ignored" 0 ""

OUT_ARGS="$("$SCRIPT" extra 2>&1)"
STATUS_ARGS=$?
if [ "$STATUS_ARGS" -eq 2 ] && [[ "$OUT_ARGS" == *"Usage:"* ]]; then
    pass "an argument is a usage error"
else
    fail "an argument is a usage error" "exit: $STATUS_ARGS (want 2)" "output: [$OUT_ARGS]"
fi

harness_report
