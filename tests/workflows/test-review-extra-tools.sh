#!/bin/bash
#
# Tests the "Check extra_allowed_tools" step of the 3 review jobs in
# claude-review.yml (issues #40, #29, #47). A caller adds rules to
# --allowedTools with extra_allowed_tools. The step must fail the job on a
# rule that reads PR comments (a gh Bash rule, a Bash rule that allows each
# command, WebFetch, a GitHub MCP rule), on a git Bash rule, and on a bare
# Read, Grep or Glob. It must pass each other rule.
#
# The test checks the text of the step in each job: its place, its env, no
# if: and no continue-on-error, no expression in run:, and the same run:
# text in the 3 jobs. Then it runs the run: block on each rule form.
#
# The test cannot check how GitHub Actions runs the workflow.
#
# WORKFLOW_DIR points the test at a copy of .github/workflows.
#
# Usage: bash tests/workflows/test-review-extra-tools.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW_DIR="${WORKFLOW_DIR:-$REAL_REPO/.github/workflows}"
REVIEW="$WORKFLOW_DIR/claude-review.yml"

TMPROOT="$(mktemp -d)"
CHECK_NAME="Check extra_allowed_tools"
# shellcheck disable=SC2016 # the expression is literal workflow text
WANT_ENV='          EXTRA_TOOLS: ${{ inputs.extra_allowed_tools }}'

if [ ! -f "$REVIEW" ]; then
    fail "claude-review.yml exists" "missing: $REVIEW"
    harness_report
fi

# job_steps <job>: prints the line number and name of each step in the job,
# as "<line> <name>". A step with no name: on its first line prints as
# "<line> -".
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

# job_head <job>: prints the job keys above its steps: list.
job_head() {
    awk -v j="$1" '
        $0 == "  " j ":" { on = 1; next }
        on && (/^    steps:/ || /^  [a-z]/) { exit }
        on { print }
    ' "$REVIEW"
}

# ------------------------------------------------------------- text checks
# <job>:<step that must come right before the check, or - for none>
for spec in pr-to-milestone-review:- milestone-review:"Stop a fork PR" comment-deep-review:-; do
    job="${spec%%:*}"
    before="${spec#*:}"
    steps="$(job_steps "$job")"

    count="$(printf '%s\n' "$steps" | grep -cF " $CHECK_NAME")"
    if [ "$count" != 1 ]; then
        fail "$job: one '$CHECK_NAME' step" "found: $count"
        continue
    fi
    pass "$job: one '$CHECK_NAME' step"

    # The step must come before the step that runs Claude.
    idx_check="$(printf '%s\n' "$steps" | grep -nF " $CHECK_NAME" | cut -d: -f1)"
    idx_claude="$(printf '%s\n' "$steps" | grep -nE ' Run Claude ' | head -n 1 | cut -d: -f1)"
    if [ -n "$idx_claude" ] && [ "$idx_check" -lt "$idx_claude" ]; then
        pass "$job: '$CHECK_NAME' comes before the Claude step"
    else
        fail "$job: '$CHECK_NAME' comes before the Claude step" "check $idx_check, claude ${idx_claude:-none}"
    fi

    if [ "$before" = "-" ]; then
        want_idx=1
        label="$job: '$CHECK_NAME' is the first step"
    else
        idx_before="$(printf '%s\n' "$steps" | grep -nF " $before" | cut -d: -f1)"
        want_idx=$(( ${idx_before:-0} + 1 ))
        label="$job: '$CHECK_NAME' comes right after '$before'"
    fi
    if [ "$idx_check" = "$want_idx" ]; then
        pass "$label"
    else
        fail "$label" "position $idx_check, want $want_idx"
    fi

    line="$(printf '%s\n' "$steps" | grep -F " $CHECK_NAME" | cut -d' ' -f1)"
    text="$(step_text "$line")"
    if printf '%s\n' "$text" | grep -qxF -- "$WANT_ENV"; then
        pass "$job: '$CHECK_NAME' reads the input through env"
    else
        fail "$job: '$CHECK_NAME' reads the input through env"
    fi
    # A job-level continue-on-error makes a failed check pass the job.
    if job_head "$job" | grep -q '^    continue-on-error:'; then
        fail "$job: the job has no continue-on-error"
    else
        pass "$job: the job has no continue-on-error"
    fi
    # An if: or continue-on-error lets the review run with a bad rule.
    if printf '%s\n' "$text" | grep -qE '^        (if|continue-on-error):'; then
        fail "$job: '$CHECK_NAME' has no if: and no continue-on-error"
    else
        pass "$job: '$CHECK_NAME' has no if: and no continue-on-error"
    fi
    step_run "$line" > "$TMPROOT/$job.sh"
    # shellcheck disable=SC2016 # the text is literal workflow text
    if grep -qF '${{' "$TMPROOT/$job.sh"; then
        fail "$job: '$CHECK_NAME' puts no expression in run:"
    else
        pass "$job: '$CHECK_NAME' puts no expression in run:"
    fi
done

for job in milestone-review comment-deep-review; do
    if [ -s "$TMPROOT/$job.sh" ] && cmp -s "$TMPROOT/pr-to-milestone-review.sh" "$TMPROOT/$job.sh"; then
        pass "$job: '$CHECK_NAME' run: text is the same as in pr-to-milestone-review"
    else
        fail "$job: '$CHECK_NAME' run: text is the same as in pr-to-milestone-review"
    fi
done

SCRIPT="$TMPROOT/pr-to-milestone-review.sh"
if [ ! -s "$SCRIPT" ]; then
    fail "the run: block of '$CHECK_NAME' exists"
    harness_report
fi

# -------------------------------------------------------------- run checks
# run_step <value>: runs the step with EXTRA_TOOLS=<value>. Sets OUT and RC.
run_step() {
    OUT="$(env -i PATH="$PATH" EXTRA_TOOLS="$1" bash "$SCRIPT" 2>&1)"
    RC=$?
}

# reject <value> [rule] [reason]: the step must exit 1 and name the rule in
# an ::error:: line. The rule is <value> when the second argument is absent
# or empty. When <reason> is given, the line must end with the rule, ". ",
# and the start of <reason>.
reject() {
    local label="reject: '$1'" rule="${2:-$1}"
    run_step "$1"
    if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" \
        | grep -qF "::error::extra_allowed_tools has a rule that this review does not allow: $rule. ${3:-}"; then
        pass "$label"
    else
        fail "$label" "exit $RC, output: $OUT"
    fi
}

# allow <value>: the step must exit 0 with no ::error:: line.
allow() {
    local label="allow: '$1'"
    run_step "$1"
    if [ "$RC" -eq 0 ] && ! printf '%s\n' "$OUT" | grep -qF '::error::'; then
        pass "$label"
    else
        fail "$label" "exit $RC, output: $OUT"
    fi
}

# gh Bash rules read PR comments.
for r in 'Bash(gh api:*)' 'Bash(gh:*)' 'Bash(gh)' 'Bash( gh pr view:*)' \
    'Bash(/usr/bin/gh issue view:*)' 'Bash(gh pr view 1 --comments)'; do
    reject "$r"
done
# Bash rules that allow each command, gh too.
for r in 'Bash' 'Bash()' 'Bash( )' 'Bash(*)' 'Bash(*:*)' 'Bash(g*:*)' 'Bash(*gh api:*)'; do
    reject "$r"
done
# git rules can write files (issue #29).
for r in 'Bash(git log:*)' 'Bash(git)' 'Bash(git:*)' 'Bash(/usr/bin/git show:*)'; do
    reject "$r"
done
# WebFetch and GitHub MCP rules read PR pages. A bare Read, Grep or Glob
# reaches each path on the runner (issue #47).
for r in 'WebFetch' 'WebFetch(domain:github.com)' 'mcp__github' 'mcp__github__get_issue' \
    'Read' 'Grep' 'Glob'; do
    reject "$r"
done
# Claude Code applies Name(), Name(*) and Name(**) as the bare Name.
for r in 'Read()' 'Read(*)' 'Read( ** )' 'Grep()' 'Grep(*)' 'Glob()' 'Glob(*)' \
    'mcp__github()' 'mcp__github(*)' 'WebFetch(*)' 'Bash(**)'; do
    reject "$r"
done

# Spaces around a rule do not hide it, and the error names the trimmed rule.
reject '  Bash(gh api:*)  ' 'Bash(gh api:*)'

# A NAME=value word or a tab before the command does not hide it.
reject 'Bash(GH_TOKEN=x gh api:*)'
reject 'Bash(A=1 B=2 git log:*)'
reject "Bash(gh	api:*)"
reject "Bash(GH_TOKEN=x	gh api:*)"
# A GitHub MCP server rule with any text in parentheses.
reject 'mcp__github(get_issue)'

# Claude Code splits --allowedTools at spaces outside parentheses too. The
# step splits at commas only, so a part that is not one rule must fail.
# A comma inside parentheses splits a rule into two broken parts.
for r in 'Bash(npm test:*) Bash(gh api:*)' 'Read(./src/**) WebFetch' 'WebSearch WebFetch' \
    'Read(./src/**) Read' 'Bash(npm test:*' 'Bash(npm (x))' 'gh api:*)' 'Bash(x:*)y'; do
    reject "$r"
done
reject 'Bash(foo,gh api:*)' 'Bash(foo'
reject 'Bash(foo,gh api:*)' 'gh api:*)'
# A quote could end the --allowedTools string in claude_args.
# shellcheck disable=SC2016 # the rules are literal input text
for r in 'x" --dangerously-skip-permissions "' 'Bash(npm "x":*)' "Bash(npm 'x':*)" 'Bash($(gh api):*)' \
    'Bash(`gh`:*)' 'Bash(npm \x:*)'; do
    reject "$r"
done

# Each kind of rule gets its own reason.
reject 'Bash(gh api:*)' '' 'gh can read each PR comment.'
reject 'Bash(*)' '' 'It allows each command, gh too.'
reject 'Bash(git log:*)' '' 'git can write files with --output.'
reject 'WebFetch' '' 'WebFetch can read PR pages.'
reject 'mcp__github__get_issue' '' 'A GitHub MCP tool can read issues and PRs.'
reject 'Read' '' 'A bare rule reaches each path on the runner.'
reject 'WebSearch WebFetch' '' 'It is not one Name or Name(...) rule'

# A list with one bad rule names only that rule.
label="a list with one bad rule names only that rule"
run_step 'Bash(npm test:*), Bash(gh api:*)'
if [ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c '::error::')" = 1 ] \
    && printf '%s\n' "$OUT" | grep -qF 'not allow: Bash(gh api:*). '; then
    pass "$label"
else
    fail "$label" "exit $RC, output: $OUT"
fi

# A list with two bad rules names each one. A line break also splits rules.
label="a list with two bad rules names each one"
run_step "WebFetch,Bash(npm test:*)
Read"
if [ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c '::error::')" = 2 ] \
    && printf '%s\n' "$OUT" | grep -qF 'not allow: WebFetch. ' \
    && printf '%s\n' "$OUT" | grep -qF 'not allow: Read. '; then
    pass "$label"
else
    fail "$label" "exit $RC, output: $OUT"
fi

# Allowed rules. A word that only starts with gh or git is not gh or git.
allow ''
allow ' , ,'
for r in 'Bash(npm test:*)' 'Bash(ghost:*)' 'Bash(github-cli-x:*)' 'Bash(gitleaks:*)' \
    'Read(./src/**)' 'Grep(./**)' 'mcp__github_inline_comment__create_inline_comment' \
    'WebSearch' 'Bash(npm test:*),Bash(composer lint:*)' 'Bash( npm test:*)' \
    'Bash(FOO=1 npm test:*)' 'Bash(npm run build --mode=x:*)' 'Bash(npm test -- a.js)'; do
    allow "$r"
done

harness_report
