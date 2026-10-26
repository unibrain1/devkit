#!/bin/bash
#
# Tests for plugins/flow/bin/flow-repo: the owner/name and the visibility come
# from `gh repo view`. A stub `gh` goes first on PATH, so there is no network
# call and no real gh.
#
# Usage: bash tests/bin/test-flow-repo.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/gh-stub.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-repo"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1
STUBDIR="$TMPROOT/bin"
gh_stub_install "$STUBDIR" || exit 1
STUB_LOG="$TMPROOT/gh.log"
export STUB_LOG

# expect <label> <want-exit> <want-stdout> <args...>
# The environment of the caller (STUB_* variables) reaches the script.
expect() {
    local label="$1" want_exit="$2" want_out="$3" out status
    shift 3
    out="$(PATH="$STUBDIR:$PATH" "$SCRIPT" "$@" 2>/dev/null)"
    status=$?
    if [ "$status" -eq "$want_exit" ] && [ "$out" = "$want_out" ]; then
        pass "$label"
    else
        fail "$label" "exit: $status (want $want_exit)" "stdout: [$out] (want [$want_out])"
    fi
}

expect "default: the stub repo name" 0 'example-org/example-repo'
STUB_REPO="acme/widgets" expect "owner/name comes from gh" 0 'acme/widgets'
expect "--visibility: the default is PRIVATE" 0 'PRIVATE' --visibility
STUB_VISIBILITY=PUBLIC expect "--visibility: PUBLIC" 0 'PUBLIC' --visibility
STUB_VISIBILITY=INTERNAL expect "--visibility: INTERNAL" 0 'INTERNAL' --visibility

: > "$STUB_LOG"
PATH="$STUBDIR:$PATH" "$SCRIPT" >/dev/null 2>&1
if grep -q '^repo view --json nameWithOwner' "$STUB_LOG"; then
    pass "the name comes from one 'gh repo view --json nameWithOwner' call"
else
    fail "the name comes from one 'gh repo view --json nameWithOwner' call" "log: $(cat "$STUB_LOG")"
fi

# gh failure and an empty answer exit 1, with the reason on stderr.
STUB_GH_FAIL_REPO_VIEW=1 expect "gh fails: exit 1, no output" 1 ''
STUB_GH_FAIL=1 expect "gh fails on every call: exit 1, no output" 1 ''
STUB_REPO="" expect "an empty answer: exit 1, no output" 1 ''
ERR_FAIL="$(STUB_GH_FAIL_REPO_VIEW=1 PATH="$STUBDIR:$PATH" "$SCRIPT" 2>&1 >/dev/null)"
if [[ "$ERR_FAIL" == *"gh could not resolve the repo"* ]]; then
    pass "a gh failure prints the reason on stderr"
else
    fail "a gh failure prints the reason on stderr" "stderr: [$ERR_FAIL]"
fi

# Usage errors.
expect "an unknown option exits 2" 2 '' --nope

harness_report
