#!/bin/bash
#
# Tests the role gate of the comment-deep-review job in claude-review.yml
# (issue #55). A "@claude deep-review" comment starts a paid deep review, so
# the job if: accepts only trusted roles. On a repo that an organization
# owns, GitHub reports an org member's comment as MEMBER. The gate must
# accept exactly OWNER, MEMBER, and COLLABORATOR. claude.yml and
# TRUSTED_COMMENTS_JQ use the same three roles, but this test checks only
# the comment-deep-review job.
#
# The test reads the workflow text. It cannot check how GitHub Actions
# evaluates the expression. It does not check the operators between the
# role terms, for example || or &&.
#
# WORKFLOW_DIR points the test at a copy of .github/workflows.
#
# Usage: bash tests/workflows/test-review-comment-roles.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW_DIR="${WORKFLOW_DIR:-$REAL_REPO/.github/workflows}"
REVIEW="$WORKFLOW_DIR/claude-review.yml"
# Sorted, with a trailing space, as check_roles prints it.
WANT="COLLABORATOR MEMBER OWNER "

TMPROOT="$(mktemp -d)"

if [ ! -f "$REVIEW" ]; then
    fail "claude-review.yml exists" "missing: $REVIEW"
    harness_report
fi

# job_if <file>
# Prints the lines of the comment-deep-review job from its key to its
# runs-on: line. The if: block is in these lines.
job_if() {
    awk '
        /^  comment-deep-review:$/ { on = 1 }
        on && /^    runs-on:/ { exit }
        on { print }
    ' "$1" 2>/dev/null
}

# check_roles <file>
# Prints nothing when the gate accepts exactly WANT. Else it prints the
# reason. Each author_association use must have the form
# "author_association == '<ROLE>'", so a new form (for example contains())
# fails here and does not hide a role.
check_roles() {
    local block roles
    block="$(job_if "$1")"
    if [ -z "$block" ]; then
        echo "no comment-deep-review job"
        return
    fi
    # Count uses, not lines: one line can hold a good use and a bad one.
    if [ "$(printf '%s\n' "$block" | grep -o 'author_association' | wc -l)" -ne \
        "$(printf '%s\n' "$block" | grep -oE "author_association == '[A-Z_]+'" | wc -l)" ]; then
        echo "an author_association use does not have the form == '<ROLE>'"
        return
    fi
    roles="$(printf '%s\n' "$block" | grep -oE "== '[A-Z_]+'" \
        | tr -d "=' " | LC_ALL=C sort -u | tr '\n' ' ')"
    if [ "$roles" != "$WANT" ]; then
        echo "roles are '$roles', want '$WANT'"
    fi
}

# expect_fail <label> <file>
# Passes when check_roles gives a reason for <file>, a mutated copy.
expect_fail() {
    if [ -n "$(check_roles "$2")" ]; then
        pass "$1"
    else
        fail "$1" "check_roles printed nothing"
    fi
}

# R1: the real workflow accepts exactly OWNER, MEMBER, and COLLABORATOR.
OUT="$(check_roles "$REVIEW")"
if [ -z "$OUT" ]; then
    pass "R1: comment-deep-review accepts exactly OWNER, MEMBER, COLLABORATOR"
else
    fail "R1: comment-deep-review accepts exactly OWNER, MEMBER, COLLABORATOR" "$OUT"
fi

# R2: a renamed job gives a reason, not a pass.
sed 's/^  comment-deep-review:$/  comment-deep-review-x:/' "$REVIEW" > "$TMPROOT/renamed.yml"
expect_fail "R2: a renamed job fails the check" "$TMPROOT/renamed.yml"

# R3: a gate with no MEMBER fails (the defect of issue #55).
grep -v "author_association == 'MEMBER'" "$REVIEW" > "$TMPROOT/no-member.yml"
expect_fail "R3: a gate with no MEMBER fails the check" "$TMPROOT/no-member.yml"

# R4: a gate that also accepts CONTRIBUTOR fails. The grep proves that the
# mutation added the line, so a changed MEMBER line cannot give a false pass.
awk '{ print } /author_association == .MEMBER. \|\|$/ {
    sub(/MEMBER/, "CONTRIBUTOR"); print }' "$REVIEW" > "$TMPROOT/contributor.yml"
if grep -q "author_association == 'CONTRIBUTOR'" "$TMPROOT/contributor.yml"; then
    expect_fail "R4: a gate that also accepts CONTRIBUTOR fails the check" "$TMPROOT/contributor.yml"
else
    fail "R4: a gate that also accepts CONTRIBUTOR fails the check" "the mutation added no CONTRIBUTOR line"
fi

# R5: a role in another form, such as contains(), fails.
sed "s/author_association == 'MEMBER'/contains('MEMBER', github.event.comment.author_association)/" \
    "$REVIEW" > "$TMPROOT/contains.yml"
expect_fail "R5: a role in another form fails the check" "$TMPROOT/contains.yml"

# R6: a line with a good use and a use in another form fails.
sed "s/author_association == 'MEMBER' ||/& contains('CONTRIBUTOR', github.event.comment.author_association) ||/" \
    "$REVIEW" > "$TMPROOT/same-line.yml"
expect_fail "R6: a second use on the same line fails the check" "$TMPROOT/same-line.yml"

harness_report
