#!/bin/bash
#
# Tests that the flow commands get the review workflow files from
# flow-review-workflow-files, not from a file name in the command text
# (issue #76). The old Step 4 of /flow:review-milestone looked only for the
# caller, so it missed a PR that changed devkit's reusable review workflow.
#
# The test checks:
#   - No command file names claude-code-review.yml or claude-review.yml.
#     A file name is a project fact (devkit CLAUDE.md: "No project facts in
#     flow").
#   - Step 4 of review-milestone.md reads the PR file list and greps it with
#     the output of flow-review-workflow-files.
#   - Step 4 has a `gh run list --workflow` command that gets the name from
#     flow-review-workflow-files.
#   - Step 4 and the exit 4 text of finish-issue.md offer
#     `Proceed without the CI review` or `Stop` for the self-review case.
#
# COMMANDS_DIR points the test at a copy of plugins/flow/commands.
#
# Usage: bash tests/commands/test-review-workflow-files.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# shellcheck disable=SC2016 # the backticks are Markdown text, not commands
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_DIR="${COMMANDS_DIR:-$REAL_REPO/plugins/flow/commands}"
MILESTONE="$COMMANDS_DIR/review-milestone.md"

if [ ! -f "$MILESTONE" ]; then
    fail "review-milestone.md exists" "missing: $MILESTONE"
    harness_report
fi

# step4 <file>
# Prints the "### Step 4" section of <file>, up to the next "### " heading.
step4() {
    awk '/^### Step 4/ { on = 1; print; next } on && /^### / { exit } on' "$1"
}

hits="$(grep -l -E 'claude-code-review\.yml|claude-review\.yml' "$COMMANDS_DIR"/*.md 2>/dev/null)"
if [ -z "$hits" ]; then
    pass "no command file names a review workflow file"
else
    fail "no command file names a review workflow file" "found in: $(tr '\n' ' ' <<< "$hits")"
fi

STEP4="$(step4 "$MILESTONE")"
if [ -z "$STEP4" ]; then
    fail "review-milestone.md has a Step 4 section"
    harness_report
fi

if grep -qE 'pulls/[^ ]*/files' <<< "$STEP4" \
    && grep -qF 'files=$(flow-review-workflow-files)' <<< "$STEP4" \
    && grep -qF 'grep -Fx -f <(printf' <<< "$STEP4"; then
    pass "Step 4: the PR file list is checked against flow-review-workflow-files"
else
    fail "Step 4: the PR file list is checked against flow-review-workflow-files" \
        "no 'pulls/.../files' call, no 'files=\$(flow-review-workflow-files)', or no 'grep -Fx -f'"
fi

run_list="$(printf '%s\n' "$STEP4" | grep -E 'gh run list --workflow')"
if [ -n "$run_list" ] && ! grep -qv 'flow-review-workflow-files' <<< "$run_list"; then
    pass "Step 4: each gh run list --workflow gets the name from flow-review-workflow-files"
else
    fail "Step 4: each gh run list --workflow gets the name from flow-review-workflow-files" \
        "lines: [$run_list]"
fi

# The self-review case must offer a way past Step 4. Without it, a milestone
# that changes the review workflow can never finish.
if grep -qF '`Proceed without the CI review` or `Stop`' <<< "$STEP4"; then
    pass "Step 4: the self-review case offers Proceed without the CI review or Stop"
else
    fail "Step 4: the self-review case offers Proceed without the CI review or Stop"
fi

FINISH="$COMMANDS_DIR/finish-issue.md"
if grep -q 'requires a merge to main first' "$FINISH" \
    && grep -qF '`Proceed without the CI review` or `Stop`' "$FINISH"; then
    pass "finish-issue.md: the self-review exit 4 offers Proceed without the CI review or Stop"
else
    fail "finish-issue.md: the self-review exit 4 offers Proceed without the CI review or Stop"
fi

harness_report
