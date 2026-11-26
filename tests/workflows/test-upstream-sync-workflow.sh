#!/bin/bash
#
# Tests that .github/workflows/upstream-sync.yml and its section in
# docs/ci-workflows.md state the manual approval step (issue #127). The
# PR's own pull_request runs wait for "Approve and run workflows", and the
# required checks come from those runs. A dispatched self-test run does not
# satisfy them, so the job must not start one, and it needs no actions
# permission.
#
# Usage: bash tests/workflows/test-upstream-sync-workflow.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$REAL_REPO/.github/workflows/upstream-sync.yml"
DOCS="$REAL_REPO/docs/ci-workflows.md"
PHRASE="Approve and run workflows"

# The header comment is the block of comment lines before "name:".
HEADER="$(sed '/^name:/q' "$WORKFLOW")"
if printf '%s\n' "$HEADER" | grep -q "^#.*${PHRASE}" \
    && printf '%s\n' "$HEADER" | grep -q '^#.*required checks'; then
    pass "header comment names the approval step"
else
    fail "header comment names the approval step" "needs: $PHRASE, and: required checks"
fi

# The docs section runs from its heading to the next "## " heading.
SECTION="$(awk '/^## `upstream-sync.yml`/ { on = 1; next } on && /^## / { exit } on' "$DOCS")"
if printf '%s\n' "$SECTION" | grep -q "$PHRASE" \
    && printf '%s\n' "$SECTION" | grep -q 'required checks'; then
    pass "docs section names the approval step"
else
    fail "docs section names the approval step" "needs: $PHRASE, and: required checks"
fi

if grep -q 'gh workflow run' "$WORKFLOW"; then
    fail "job starts no workflow with gh workflow run"
else
    pass "job starts no workflow with gh workflow run"
fi

if grep -Eq '^[[:space:]]+actions:[[:space:]]' "$WORKFLOW"; then
    fail "job has no actions permission"
else
    pass "job has no actions permission"
fi

harness_report
