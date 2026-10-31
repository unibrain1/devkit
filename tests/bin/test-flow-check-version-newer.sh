#!/bin/bash
#
# Tests for flow-check-version-newer: numeric comparison of a
# candidate version with the last release tag, including the optional
# fourth number of a patch release from main (v2.30.4.1). The candidate
# must start with 'v'. The last tag may lack it.
#
# HERMETIC: each expect case passes the last tag as the second argument,
# so the script does not run `git describe`. The expect_stderr cases run in
# a temp dir that is not a git repo. Each other `git describe` case runs in
# a throwaway repo under the temp dir. No case reads the devkit tags.
#
# Usage: bash tests/bin/test-flow-check-version-newer.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-check-version-newer"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1

# A GIT_DIR or GIT_WORK_TREE from the caller would send the fixture's git
# init, commit, and tag to the caller's repo, not to $TMPROOT.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

# expect <want-exit> <candidate> <last-tag>
expect() {
    local want="$1" candidate="$2" last="$3" out status
    out="$("$SCRIPT" "$candidate" "$last" 2>&1)"
    status=$?
    if [ "$status" -eq "$want" ]; then
        pass "$candidate vs $last -> exit $want"
    else
        fail "$candidate vs $last -> exit $want" "exit: $status output: [$out]"
    fi
}

# Three-part versions.
expect 0 v2.30.5 v2.30.4
expect 0 v2.31.0 v2.30.9
expect 0 v3.0.0 v2.99.99
expect 0 v2.10.0 v2.9.0
expect 1 v2.30.4 v2.30.4
expect 1 v2.30.3 v2.30.4
expect 1 v2.9.0 v2.10.0

# Four-part patch-release tags: v2.30.5 > v2.30.4.1 > v2.30.4.
expect 0 v2.30.5 v2.30.4.1
expect 0 v2.30.4.1 v2.30.4
expect 0 v2.30.4.2 v2.30.4.1
expect 0 v2.30.4.10 v2.30.4.9
expect 1 v2.30.4 v2.30.4.1
expect 1 v2.30.4.1 v2.30.4.1
expect 1 v2.30.4.1 v2.30.5
expect 1 v2.30.4.0 v2.30.4

# Versions the script cannot parse.
expect 2 v2.30 v2.30.4
expect 2 v2.30.5 v2.30.4.1.1
expect 2 v2.30.5 v2.30.4-rc1
expect 2 v2.30.5 latest

# The candidate needs a leading 'v'. The last tag does not.
expect 2 2.30.5 v2.30.4
expect 2 2.30.4.1 v2.30.4
expect 0 v2.30.5 2.30.4
expect 1 v2.30.3 2.30.4

# Exit 2 names the expected form. Exit 1 names the last tag.
# expect_stderr <want-exit> <text> <arg>...
# It runs the script in $TMPROOT, which is not a git repo. A case with no
# last tag then cannot read the devkit tags. This holds even if the script
# runs git describe first.
expect_stderr() {
    local want="$1" text="$2" out status
    shift 2
    out="$(cd "$TMPROOT" && env -u GIT_DIR GIT_CEILING_DIRECTORIES="$TMPROOT" "$SCRIPT" "$@" 2>&1 >/dev/null)"
    status=$?
    if [ "$status" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$text"; then
        pass "[$*] -> exit $want, stderr has '$text'"
    else
        fail "[$*] -> exit $want, stderr has '$text'" "exit: $status stderr: [$out]"
    fi
}
expect_stderr 2 'vX.Y.Z or vX.Y.Z.N' 1.2.0 v1.1.0
expect_stderr 2 'vX.Y.Z or vX.Y.Z.N' v1.2 v1.1.0
expect_stderr 2 'vX.Y.Z or vX.Y.Z.N' '' v1.1.0
expect_stderr 2 'vX.Y.Z or vX.Y.Z.N'
expect_stderr 2 'Usage: flow-check-version-newer'
expect_stderr 1 'v2.30.4' v2.30.3 v2.30.4

# Step 0b in plan-milestone.md and start-milestone.md picks its exit 2 path
# from these three texts. A reworded message breaks that choice.
expect_stderr 2 'Could not parse candidate version' 1.2.0 v1.1.0
expect_stderr 2 'Could not parse last tag' v1.2.0 latest
expect_stderr 2 'git describe --tags --abbrev=0 failed' v1.2.0

# --- Last tag from `git describe` is a four-part tag -> exit 0 ------------
REPO="$TMPROOT/repo"
mkdir -p "$REPO"
(
    cd "$REPO" || exit 1
    git init -q
    git config user.name "test-check-version-newer"
    git config user.email "test-check-version-newer@localhost"
    git commit -q --allow-empty -m "release"
    git tag -a v2.30.4 -m "v2.30.4"
    git commit -q --allow-empty -m "hotfix"
    git tag -a v2.30.4.1 -m "v2.30.4.1"
) || exit 1
OUT="$(cd "$REPO" && "$SCRIPT" v2.30.5 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -q 'v2.30.5 is newer than v2.30.4.1'; then
    pass "last tag from git describe is v2.30.4.1 -> exit 0"
else
    fail "last tag from git describe is v2.30.4.1 -> exit 0" "exit: $STATUS output: [$OUT]"
fi

# --- A repo with no tags: git describe fails -> exit 2 ---------------------
NOTAGS="$TMPROOT/notags"
mkdir -p "$NOTAGS"
(
    cd "$NOTAGS" || exit 1
    git init -q
    git config user.name "test-check-version-newer"
    git config user.email "test-check-version-newer@localhost"
    git commit -q --allow-empty -m "first"
) || exit 1
OUT="$(cd "$NOTAGS" && "$SCRIPT" v1.2.0 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'git describe --tags --abbrev=0 failed'; then
    pass "repo with no tags -> exit 2, git describe message"
else
    fail "repo with no tags -> exit 2, git describe message" "exit: $STATUS output: [$OUT]"
fi

# The script checks the candidate before git describe, so a bad candidate
# gets the form message, not the git describe message.
OUT="$(cd "$NOTAGS" && "$SCRIPT" 1.2.0 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'Could not parse candidate version' \
    && ! printf '%s' "$OUT" | grep -qF 'git describe'; then
    pass "bad candidate in a repo with no tags -> form message only"
else
    fail "bad candidate in a repo with no tags -> form message only" "exit: $STATUS output: [$OUT]"
fi

# --- Nearest tag is not a release tag -> exit 2, last tag message -----------
(
    cd "$NOTAGS" || exit 1
    git tag skills-latest
) || exit 1
OUT="$(cd "$NOTAGS" && "$SCRIPT" v1.2.0 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && printf '%s' "$OUT" | grep -qF "Could not parse last tag 'skills-latest'"; then
    pass "nearest tag skills-latest -> exit 2, last tag message"
else
    fail "nearest tag skills-latest -> exit 2, last tag message" "exit: $STATUS output: [$OUT]"
fi

harness_report
