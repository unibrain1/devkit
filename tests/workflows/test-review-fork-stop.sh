#!/bin/bash
#
# Tests the fork stop of the 3 review jobs in claude-review.yml (issue #42).
# A fork PR must not get a review, and it must not get a green check.
#   - pr-to-milestone-review and comment-deep-review stop a fork PR in their
#     "Resolve PR context" step. The test checks that each step has the check.
#   - milestone-review stops it in its first step, "Stop a fork PR". The
#     step must fail the job: no if:, no continue-on-error. The reason is in
#     docs/ci-workflows.md, "Fork PRs". The test also runs the run: block of
#     the step with a fake gh.
#
# The test cannot check how GitHub Actions runs the workflow.
#
# WORKFLOW_DIR points the test at a copy of .github/workflows.
#
# Usage: bash tests/workflows/test-review-fork-stop.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/gh-stub.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW_DIR="${WORKFLOW_DIR:-$REAL_REPO/.github/workflows}"
REVIEW="$WORKFLOW_DIR/claude-review.yml"

TMPROOT="$(mktemp -d)"
BIN="$TMPROOT/bin"
gh_stub_install "$BIN"

STOP_NAME="Stop a fork PR"
CHECK='--json isCrossRepository -q .isCrossRepository'
# shellcheck disable=SC2016 # the text is literal workflow text
STOP_TEST='if [ "$CROSS" != "false" ]; then'

if [ ! -f "$REVIEW" ]; then
    fail "claude-review.yml exists" "missing: $REVIEW"
    harness_report
fi

# job_steps <job>: prints the line number and name of each step in the job,
# as "<line> <name>". A step with no name: on its first line prints as
# "<line> -", so an unnamed step before the stop step is not missed.
job_steps() {
    awk -v j="$1" '
        /^  [a-z][a-z0-9-]*:$/ { cur = $0; sub(/^ +/, "", cur); sub(/:$/, "", cur) }
        cur == j && /^      - / {
            n = $0
            if (!sub(/^      - name: /, "", n)) n = "-"
            print NR " " n
        }
    ' "$REVIEW"
}

# job_head <job>: prints the job keys above its steps: list.
job_head() {
    awk -v j="$1" '
        $0 == "  " j ":" { on = 1; next }
        on && (/^    steps:/ || /^  [a-z]/) { exit }
        on { print }
    ' "$REVIEW"
}

# step_text <line>: prints the step that starts at the line, up to the next
# step or job.
step_text() {
    awk -v s="$1" '
        NR == s { on = 1; print; next }
        on && (/^      - / || /^  [a-z]/) { exit }
        on { print }
    ' "$REVIEW"
}

# step_run <line>: prints the run: block of the step, with its indent removed.
step_run() {
    awk -v s="$1" '
        NR <= s { next }
        done { next }
        /^      - / || /^  [a-z]/ { done = 1; next }
        on && !/^ *$/ && !/^          / { done = 1; next }
        on { sub(/^          /, ""); print }
        /^        run: \|$/ { on = 1 }
    ' "$REVIEW"
}

# ------------------------------------------- the two jobs with a PR number
for job in pr-to-milestone-review comment-deep-review; do
    label="$job: Resolve PR context stops a PR that is not isCrossRepository false"
    line="$(job_steps "$job" | grep -F ' Resolve PR context' | cut -d' ' -f1)"
    text="$(step_text "${line:-0}")"
    if [ -n "$line" ] && printf '%s\n' "$text" | grep -qF -- "$CHECK" \
        && printf '%s\n' "$text" | grep -qF -- "$STOP_TEST"; then
        pass "$label"
    else
        fail "$label"
    fi
done

# --------------------------------------------------------- milestone-review
first="$(job_steps milestone-review | head -n 1)"
first_line="${first%% *}"
first_name="${first#* }"
if [ "$first_name" != "$STOP_NAME" ]; then
    fail "milestone-review: the first step is '$STOP_NAME'" "found: '$first_name'"
    harness_report
fi
pass "milestone-review: the first step is '$STOP_NAME'"

# A job-level continue-on-error makes a failed job pass. A fork condition
# in the job if: skips the job, and a skipped job passes a required check.
job_keys="$(job_head milestone-review)"
if printf '%s\n' "$job_keys" | grep -q '^    continue-on-error:'; then
    fail "milestone-review: the job has no continue-on-error"
else
    pass "milestone-review: the job has no continue-on-error"
fi
if printf '%s\n' "$job_keys" | grep -qE 'head\.repo|\.fork|isCrossRepository'; then
    fail "milestone-review: the job if: has no fork condition"
else
    pass "milestone-review: the job if: has no fork condition"
fi

text="$(step_text "$first_line")"
# An if: or continue-on-error lets the job go on, and its Gate can then pass.
if printf '%s\n' "$text" | grep -qE '^        (if|continue-on-error):'; then
    fail "milestone-review: '$STOP_NAME' has no if: and no continue-on-error"
else
    pass "milestone-review: '$STOP_NAME' has no if: and no continue-on-error"
fi

# Each value comes through env, never as ${{ }} text in run:.
# shellcheck disable=SC2016 # the text is literal workflow text
if step_run "$first_line" | grep -qF '${{'; then
    fail "milestone-review: '$STOP_NAME' puts no expression in run:"
else
    pass "milestone-review: '$STOP_NAME' puts no expression in run:"
fi

SCRIPT="$TMPROOT/stop.sh"
step_run "$first_line" > "$SCRIPT"

# run_case <label> <want> <fixture-json> [VAR=value ...]: runs the step with
# the fixture as the gh pr view answer. <want> is one of:
#   pass  exit 0
#   fork  exit 1 with the fork message
#   odd   exit 1 with the message for a value that is not true or false
#   stop  non-zero exit with no ::error:: line: set -e stops the step at the
#         failed gh call, before any test of the value
run_case() {
    local label="milestone-review: $1" want="$2" fixture="$3" out rc ok=0
    shift 3
    printf '%s\n' "$fixture" > "$TMPROOT/pr.json"
    out="$(env -i PATH="$BIN:$PATH" GH_TOKEN=x PR_NUM=7 REPO=o/r \
        STUB_PR_JSON="$TMPROOT/pr.json" "$@" bash "$SCRIPT" 2>&1)"
    rc=$?
    case "$want" in
        pass) [ "$rc" -eq 0 ] && ok=1 ;;
        fork) [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF '::error::PR #7 comes from a fork.' && ok=1 ;;
        odd) [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "::error::gh pr view gave isCrossRepository 'null' for PR #7" && ok=1 ;;
        stop) [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -qF '::error::' && ok=1 ;;
    esac
    if [ "$ok" = 1 ]; then
        pass "$label"
    else
        fail "$label" "exit $rc, output: $out"
    fi
}

run_case "a same-repository PR goes on" pass '{"isCrossRepository":false}'
run_case "a fork PR stops with the fork message" fork '{"isCrossRepository":true}'
run_case "a missing isCrossRepository field stops the job" odd '{}'
run_case "a failed gh pr view stops the job" stop '{"isCrossRepository":false}' STUB_GH_FAIL_PR_VIEW=1

harness_report
