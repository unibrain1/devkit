#!/bin/bash
#
# Regression test for flow-check-required-checks (#111).
#
# The script reads the `required_checks` key and the output of
# `gh pr checks <pr> --json name,bucket`. A listed name passes only when an
# entry with that name has bucket pass and no entry with that name has
# bucket fail, cancel, or pending.
#
# HERMETIC: a throwaway git repo (mktemp -d) holds .claude/project.md. The
# shared stub in lib/gh-stub.sh goes first on PATH. Its STUB_EXTRA handler
# answers `gh pr checks` from a fixture file, with the exit code that real gh
# gives. No network and no real gh.
#
# Usage: bash tests/bin/test-flow-check-required-checks.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The project.md lines hold literal backticks, so single quotes are on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/gh-stub.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-check-required-checks"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1

STUBDIR="$TMPROOT/bin"
gh_stub_install "$STUBDIR" || exit 1

REPO="$TMPROOT/repo"
git init -q "$REPO" >/dev/null 2>&1
cd "$REPO" || exit 1

# The STUB_EXTRA handler answers only `gh pr checks`. It prints
# $STUB_CHECKS_JSON (when set) to stdout and $STUB_CHECKS_ERR (when set) to
# stderr. Then it exits $STUB_CHECKS_RC.
export STUB_EXTRA="$TMPROOT/gh-extra"
cat > "$STUB_EXTRA" <<'EXTRA'
#!/bin/bash
[ "${1:-}" = "pr" ] && [ "${2:-}" = "checks" ] || exit 3
[ -n "${STUB_CHECKS_JSON:-}" ] && cat "$STUB_CHECKS_JSON"
[ -n "${STUB_CHECKS_ERR:-}" ] && printf '%s\n' "$STUB_CHECKS_ERR" >&2
exit "${STUB_CHECKS_RC:-0}"
EXTRA
chmod +x "$STUB_EXTRA"

STUB_LOG="$TMPROOT/gh.log"
export STUB_LOG

# checks_json <name> <bucket> [<name> <bucket> ...]: writes the fixture.
checks_json() {
    local out="$TMPROOT/checks.json" items=""
    while [ "$#" -ge 2 ]; do
        items="${items}$(jq -cn --arg n "$1" --arg b "$2" '{name: $n, bucket: $b}')"$'\n'
        shift 2
    done
    if [ -z "$items" ]; then
        echo '[]' > "$out"
    else
        printf '%s' "$items" | jq -s '.' > "$out"
    fi
    STUB_CHECKS_JSON="$out"
}

# run_check <pr-arg>...: runs the script. stdout goes to $TMPROOT/out,
# stderr to $TMPROOT/err. Sets S to the exit code.
run_check() {
    : > "$STUB_LOG"
    PATH="$STUBDIR:$PATH" STUB_CHECKS_JSON="${STUB_CHECKS_JSON:-}" \
        STUB_CHECKS_ERR="${STUB_CHECKS_ERR:-}" STUB_CHECKS_RC="${STUB_CHECKS_RC:-0}" \
        "$SCRIPT" "$@" > "$TMPROOT/out" 2> "$TMPROOT/err"
    S=$?
    OUT="$(cat "$TMPROOT/out")"
    ERR="$(cat "$TMPROOT/err")"
}

# expect <label> <want-exit> <want-stdout> [<want-stderr-substring>]
# The stdout must be equal to <want-stdout>.
expect() {
    local label="$1" want_exit="$2" want_out="$3" want_err="${4:-}"
    if [ "$S" -eq "$want_exit" ] && [ "$OUT" = "$want_out" ] \
        && { [ -z "$want_err" ] || [[ "$ERR" == *"$want_err"* ]]; }; then
        pass "$label"
    else
        fail "$label" "exit: $S (want $want_exit)" "stdout: [$OUT] (want [$want_out])" \
            "stderr: [$ERR]${want_err:+ (want *$want_err*)}"
    fi
}

reset_stub() {
    STUB_CHECKS_JSON=""
    STUB_CHECKS_ERR=""
    STUB_CHECKS_RC=0
}

TWO='required_checks: `Test & Coverage, secrets-scan / trufflehog`'

# --- R1: no key -> exit 10 ---------------------------------------------------
reset_stub
project_md_write "$REPO" 'test: `t`' 'lint: `l`'
checks_json "Test & Coverage" pass
run_check 7
if [ "$S" -eq 10 ] && [ -z "$OUT" ] && [[ "$ERR" == *"Step skipped."* ]] \
    && ! grep -q '^pr checks' "$STUB_LOG"; then
    pass "R1: no required_checks key -> exit 10, no gh pr checks call"
else
    fail "R1: no required_checks key -> exit 10, no gh pr checks call" \
        "exit: $S (want 10)" "stdout: [$OUT]" "stderr: [$ERR]" "gh calls: [$(cat "$STUB_LOG")]"
fi

project_md_write "$REPO" 'test: `t`' 'lint: `l`' "$TWO"

# --- R2: each check passes -> exit 0 -----------------------------------------
reset_stub
checks_json "Test & Coverage" pass "secrets-scan / trufflehog" pass "lint" fail
run_check 7
if [ "$S" -eq 0 ] && [ -z "$OUT" ] && grep -q '^pr checks 7 --repo example-org/example-repo --json name,bucket$' "$STUB_LOG"; then
    pass "R2: each listed check passes (an unlisted check fails) -> exit 0"
else
    fail "R2: each listed check passes (an unlisted check fails) -> exit 0" \
        "exit: $S (want 0)" "stdout: [$OUT]" "stderr: [$ERR]" "gh calls: [$(cat "$STUB_LOG")]"
fi

# --- R3: one check is missing -> exit 1 --------------------------------------
reset_stub
checks_json "Test & Coverage" pass
run_check 7
expect "R3: one listed check is missing -> exit 1, name printed" 1 \
    "secrets-scan / trufflehog: missing"

# --- R4: one check is skipping -> exit 1 -------------------------------------
reset_stub
checks_json "Test & Coverage" skipping "secrets-scan / trufflehog" pass
run_check 7
expect "R4: one listed check is skipping -> exit 1" 1 "Test & Coverage: skipping"

# --- R5: one check is pending, gh exits 8 -> exit 1 --------------------------
reset_stub
checks_json "Test & Coverage" pending "secrets-scan / trufflehog" pass
STUB_CHECKS_RC=8
run_check 7
expect "R5: one listed check is pending, gh exits 8 -> exit 1" 1 "Test & Coverage: pending"

# --- R6: one check fails, gh exits 1 -> exit 1 -------------------------------
reset_stub
checks_json "Test & Coverage" pass "secrets-scan / trufflehog" fail
STUB_CHECKS_RC=1
run_check 7
expect "R6: one listed check fails, gh exits 1 -> exit 1" 1 "secrets-scan / trufflehog: fail"

# --- R6b: one check is cancelled -> exit 1 -----------------------------------
reset_stub
checks_json "Test & Coverage" cancel "secrets-scan / trufflehog" pass
run_check 7
expect "R6b: one listed check is cancelled -> exit 1" 1 "Test & Coverage: cancel"

# --- R7: two entries with one name, pass + pass -> exit 0 --------------------
reset_stub
checks_json "Test & Coverage" pass "Test & Coverage" pass "secrets-scan / trufflehog" pass
run_check 7
expect "R7: two entries with one name, pass + pass -> exit 0" 0 ""

# --- R8: two entries with one name, pass + fail -> exit 1 --------------------
reset_stub
checks_json "Test & Coverage" pass "Test & Coverage" fail "secrets-scan / trufflehog" pass
STUB_CHECKS_RC=1
run_check 7
expect "R8: two entries with one name, pass + fail -> exit 1" 1 "Test & Coverage: fail"

# --- R8b: two entries with one name, pass + skipping -> exit 0 ---------------
reset_stub
checks_json "Test & Coverage" skipping "Test & Coverage" pass "secrets-scan / trufflehog" pass
run_check 7
expect "R8b: two entries with one name, pass + skipping -> exit 0" 0 ""

# --- R8c: two entries with one name, pass + pending -> exit 1 ----------------
reset_stub
checks_json "Test & Coverage" pass "Test & Coverage" pending "secrets-scan / trufflehog" pass
STUB_CHECKS_RC=8
run_check 7
expect "R8c: two entries with one name, pass + pending -> exit 1" 1 "Test & Coverage: pending"

# --- R9: names with spaces, &, /, and a parenthesis; extra spaces -----------
# A name that is only a part of a real name must not match it.
reset_stub
project_md_write "$REPO" 'test: `t`' 'lint: `l`' \
    'required_checks: `   Test & Coverage ,secrets-scan / trufflehog,  test (macos-15)  `'
checks_json "Test & Coverage" pass "secrets-scan / trufflehog" pass "test (macos-15)" pass
run_check 7
expect "R9: names with spaces, &, / and extra spaces around the commas -> exit 0" 0 ""

checks_json "Test & Coverage extra" pass "secrets-scan / trufflehog" pass "test (macos-15)" pass
run_check 7
expect "R9b: a longer name does not match the listed name -> missing" 1 "Test & Coverage: missing"

checks_json "Test & Coverage" fail "secrets-scan / trufflehog" pending "test (macos-15)" skipping
run_check 7
expect "R9c: three bad checks -> one line for each, in key order" 1 \
    "Test & Coverage: fail
secrets-scan / trufflehog: pending
test (macos-15): skipping"

# --- R10: the key has no name -> exit 2 --------------------------------------
reset_stub
checks_json "Test & Coverage" pass
for value in '' '  ' ' , ,'; do
    project_md_write "$REPO" 'test: `t`' 'lint: `l`' "required_checks: \`${value}\`"
    run_check 7
    expect "R10: required_checks value [${value}] -> exit 2" 2 "" "has no check name"
done
project_md_write "$REPO" 'test: `t`' 'lint: `l`' "$TWO"

# --- R11: gh fails with no JSON -> exit 3 ------------------------------------
reset_stub
STUB_CHECKS_ERR="HTTP 401: Bad credentials"
STUB_CHECKS_RC=1
run_check 7
expect "R11: gh fails with no JSON -> exit 3, cannot verify" 3 "" "NOT the same as 'the checks passed'"

reset_stub
printf 'not json\n' > "$TMPROOT/bad.json"
STUB_CHECKS_JSON="$TMPROOT/bad.json"
run_check 7
expect "R11b: gh exits 0 with output that is not JSON -> exit 3" 3 "" "cannot verify"

reset_stub
printf '{"name": "Test & Coverage", "bucket": "pass"}\n' > "$TMPROOT/obj.json"
STUB_CHECKS_JSON="$TMPROOT/obj.json"
run_check 7
expect "R11c: gh prints a JSON object, not an array -> exit 3" 3 "" "cannot verify"

# --- R12: flow-repo fails -> exit 3 ------------------------------------------
reset_stub
checks_json "Test & Coverage" pass "secrets-scan / trufflehog" pass
STUB_GH_FAIL_REPO_VIEW=1 run_check 7
expect "R12: flow-repo cannot resolve the repo -> exit 3" 3 "" "flow-repo"

# --- R13: no checks reported -> each listed check is missing -----------------
reset_stub
STUB_CHECKS_ERR="no checks reported on the 'issue/111-required-checks' branch"
STUB_CHECKS_RC=1
run_check 7
expect "R13: gh reports no checks -> exit 1, each name missing" 1 \
    "Test & Coverage: missing
secrets-scan / trufflehog: missing"

# --- R14: usage errors -> exit 2 ---------------------------------------------
reset_stub
checks_json "Test & Coverage" pass "secrets-scan / trufflehog" pass
run_check
expect "R14: no PR argument -> exit 2" 2 "" "Usage:"
run_check abc
expect "R14b: a PR argument that is not a number -> exit 2" 2 "" "Usage:"
run_check 7 8
expect "R14c: two arguments -> exit 2" 2 "" "Usage:"

harness_report
