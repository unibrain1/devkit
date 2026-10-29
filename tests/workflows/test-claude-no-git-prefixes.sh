#!/bin/bash
#
# Tests that no claude-code-action step has a git rule in the
# --allowedTools value of its claude_args (issue #29). A prefix rule such as
# "Bash(git log:*)" also allows "git log --output=<file>", and that writes a
# file such as $GITHUB_ENV. A deny rule cannot block it: in the issue #29
# probe, a quote split the flag (--'output'), and the matcher read the text
# before the shell removed the quotes. The test cannot see the rules that
# the action adds in tag mode, or a caller's extra_allowed_tools.
#
# WORKFLOW_DIR points the test at a copy of .github/workflows.
#
# Usage: bash tests/workflows/test-claude-no-git-prefixes.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW_DIR="${WORKFLOW_DIR:-$REAL_REPO/.github/workflows}"

# bad_steps <file>
# Prints "<file>:<line> <reason>" for each claude-code-action step that has
# a git rule in its claude_args block, or no claude_args block. A git rule
# is "Bash(git" and then a space, ":", "*" or ")". The claude_args block
# ends at the next line with the same or a lower indent. A step ends at the
# next line that starts a step ("- ") at the same or a lower indent. A git
# rule outside claude_args (a comment, a run: script) does not count.
bad_steps() {
    awk -v file="$1" '
        function indent(s) { match(s, /^ */); return RLENGTH }
        function close_step() {
            if (in_step && !has_args) print file ":" start " no claude_args"
            if (in_step && git_line) print file ":" git_line " git rule in claude_args"
            in_step = 0; in_args = 0
        }
        in_step && /^ *- / && indent($0) <= step_indent { close_step() }
        in_args && /[^ ]/ && indent($0) <= args_indent { in_args = 0 }
        /uses: anthropics\/claude-code-action@/ {
            close_step()
            in_step = 1; has_args = 0; git_line = 0; start = NR
            # "- uses:" starts the step itself. "uses:" under "- name:" is
            # 2 columns deeper than the "- ".
            step_indent = /^ *- / ? indent($0) : indent($0) - 2
            next
        }
        in_args && /Bash\(git[ :*)]/ && !git_line { git_line = NR }
        in_step && /^ *claude_args:/ {
            in_args = 1; has_args = 1; args_indent = indent($0)
            if ($0 ~ /Bash\(git[ :*)]/) git_line = NR
        }
        END { close_step() }
    ' "$1"
}

files="$(grep -l 'uses: anthropics/claude-code-action@' "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml 2>/dev/null)"
if [ -z "$files" ]; then
    fail "a workflow uses claude-code-action" "none in $WORKFLOW_DIR"
fi

total=0
for path in $files; do
    f="$(basename "$path")"
    n="$(grep -c 'uses: anthropics/claude-code-action@' "$path")"
    total=$((total + n))
    bad="$(bad_steps "$path")"
    if [ -z "$bad" ]; then
        pass "$f: no git rule in the claude_args of $n claude-code-action step(s)"
    else
        fail "$f: no git rule in claude_args" "$bad"
    fi
done

# The workflows have 4 steps today: 3 review jobs and @claude. A new step
# changes this count, so the person who adds it reads this test.
if [ "$total" -eq 4 ]; then
    pass "4 claude-code-action steps in total"
else
    fail "4 claude-code-action steps in total" "found $total"
fi

TMPROOT="$(mktemp -d)"

# Negative case: a git prefix in --allowedTools must fail the check.
sed 's/Bash(gh pr diff:\*)/Bash(gh pr diff:*),Bash(git log:*)/' \
    "$WORKFLOW_DIR/claude.yml" > "$TMPROOT/with-git.yml"
if [ -n "$(bad_steps "$TMPROOT/with-git.yml")" ]; then
    pass "a git prefix in --allowedTools fails the check"
else
    fail "a git prefix in --allowedTools fails the check"
fi

# A rule with no subcommand, "Bash(git:*)", allows every git command and
# must fail the check too.
sed 's/Bash(gh pr diff:\*)/Bash(gh pr diff:*),Bash(git:*)/' \
    "$WORKFLOW_DIR/claude.yml" > "$TMPROOT/git-any.yml"
if [ -n "$(bad_steps "$TMPROOT/git-any.yml")" ]; then
    pass "Bash(git:*) in --allowedTools fails the check"
else
    fail "Bash(git:*) in --allowedTools fails the check"
fi

# A git rule in the last of 3 steps must fail the check at that step's
# line. claude.yml has only 1 step, so this case tests the step boundary.
last="$(grep -n '"mcp__github_inline_comment' "$WORKFLOW_DIR/claude-review.yml" | tail -1 | cut -d: -f1)"
awk -v n="$last" 'NR == n { sub(/Read,/, "Bash(git show:*),Read,") } { print }' \
    "$WORKFLOW_DIR/claude-review.yml" > "$TMPROOT/last-step.yml"
if bad_steps "$TMPROOT/last-step.yml" | grep -q ":$last git rule"; then
    pass "a git rule in the last step fails the check at line $last"
else
    fail "a git rule in the last step fails the check at line $last"
fi

# A git rule outside claude_args (here, a comment above it) must
# not fail the check.
awk '/^ *claude_args:/ { print "          # Bash(git log:*) is not allowed." } { print }' \
    "$WORKFLOW_DIR/claude.yml" > "$TMPROOT/comment.yml"
if [ -z "$(bad_steps "$TMPROOT/comment.yml")" ]; then
    pass "a git rule outside claude_args does not fail the check"
else
    fail "a git rule outside claude_args does not fail the check"
fi

# A step with no claude_args must fail the check: with no --allowedTools,
# the action does not limit Claude to the read-only tools.
grep -v -e 'claude_args:' -e '--allowedTools' -e '"Bash(gh pr comment' \
    "$WORKFLOW_DIR/claude.yml" > "$TMPROOT/no-args.yml"
if bad_steps "$TMPROOT/no-args.yml" | grep -q 'no claude_args'; then
    pass "a step with no claude_args fails the check"
else
    fail "a step with no claude_args fails the check"
fi

harness_report
