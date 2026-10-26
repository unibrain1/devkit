#!/bin/bash
#
# Tests for plugins/flow/bin/flow-milestone-count: the count of milestone/*
# branches on origin, and the limit check (1 for a private repo, 2 for a
# public repo).
#
# HERMETIC: each case uses a throwaway repo with a throwaway bare "origin"
# (mktemp -d). A stub `gh` goes first on PATH for the visibility. No network.
#
# Usage: bash tests/bin/test-flow-milestone-count.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/gh-stub.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

export GIT_AUTHOR_NAME="test-flow-milestone-count"
export GIT_AUTHOR_EMAIL="test-flow-milestone-count@localhost"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-milestone-count"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1
STUBDIR="$TMPROOT/bin"
gh_stub_install "$STUBDIR" || exit 1

ORIGIN="$TMPROOT/origin.git"
REPO="$TMPROOT/repo"
git init -q --bare "$ORIGIN" >/dev/null 2>&1
git init -q "$REPO" >/dev/null 2>&1
cd "$REPO" || exit 1
git config commit.gpgsign false
git symbolic-ref HEAD refs/heads/main
git remote add origin "$ORIGIN"
echo base > README.md
git add README.md
git commit -q -m initial
git push -q origin main

# run <args...>: sets OUT (stdout), ERR (stderr) and STATUS. The STUB_*
# variables of the caller reach the script.
run() {
    PATH="$STUBDIR:$PATH" "$SCRIPT" "$@" > "$TMPROOT/out" 2> "$TMPROOT/err"
    STATUS=$?
    OUT="$(cat "$TMPROOT/out")"
    ERR="$(cat "$TMPROOT/err")"
}

# expect <label> <want-exit> <want-stdout>
expect() {
    if [ "$STATUS" -eq "$2" ] && [ "$OUT" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "exit: $STATUS (want $2)" "stdout: [$OUT] (want [$3])" "stderr: [$ERR]"
    fi
}

# --- No milestone branch ------------------------------------------------------
run
expect "no milestone branch: prints 0" 0 "0"
STUB_VISIBILITY=PRIVATE run --check
expect "--check, private, 0 branches: exit 0" 0 "0"

# --- One milestone branch ------------------------------------------------------
git push -q origin main:refs/heads/milestone/v1.0.0
run
expect "one milestone branch: prints 1" 0 "1"
STUB_VISIBILITY=PRIVATE run --check
expect "--check, private, 1 branch: at the limit, exit 1" 1 "1"
if [[ "$ERR" == *"limit for a PRIVATE repo is 1"* ]] && [[ "$ERR" == *"milestone/v1.0.0"* ]]; then
    pass "--check, private, 1 branch: stderr names the branch and the limit"
else
    fail "--check, private, 1 branch: stderr names the branch and the limit" "stderr: [$ERR]"
fi
STUB_VISIBILITY=PUBLIC run --check
expect "--check, public, 1 branch: under the limit, exit 0" 0 "1"

# --- Two milestone branches ----------------------------------------------------
git push -q origin main:refs/heads/milestone/v1.1.0
run
expect "two milestone branches: prints 2" 0 "2"
STUB_VISIBILITY=PUBLIC run --check
expect "--check, public, 2 branches: at the limit, exit 1" 1 "2"
STUB_VISIBILITY=INTERNAL run --check
expect "--check, internal, 2 branches: the private limit applies, exit 1" 1 "2"

# --- Other branches do not count -------------------------------------------------
git push -q origin main:refs/heads/issue/5-thing main:refs/heads/milestones-notes
run
expect "branches that are not milestone/* do not count" 0 "2"

# --- Errors ------------------------------------------------------------------
STUB_GH_FAIL_REPO_VIEW=1 run --check
if [ "$STATUS" -eq 2 ] && [[ "$ERR" == *"flow-repo"* ]]; then
    pass "--check, gh cannot give the visibility: exit 2"
else
    fail "--check, gh cannot give the visibility: exit 2" "exit: $STATUS (want 2)" "stderr: [$ERR]"
fi
STUB_GH_FAIL_REPO_VIEW=1 run
expect "no --check: gh is not called, prints 2" 0 "2"

run --nope
if [ "$STATUS" -eq 2 ] && [[ "$ERR" == *"Usage:"* ]]; then
    pass "an unknown option exits 2 with a usage line"
else
    fail "an unknown option exits 2 with a usage line" "exit: $STATUS (want 2)" "stderr: [$ERR]"
fi

git remote set-url origin "$TMPROOT/does-not-exist.git"
run
if [ "$STATUS" -eq 2 ] && [[ "$ERR" == *"git ls-remote failed"* ]]; then
    pass "git ls-remote fails: exit 2"
else
    fail "git ls-remote fails: exit 2" "exit: $STATUS (want 2)" "stderr: [$ERR]"
fi

harness_report
