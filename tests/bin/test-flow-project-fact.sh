#!/bin/bash
#
# Tests for plugins/flow/bin/flow-project-fact: value parsing, and the exit
# codes 0 (found), 1 (key absent) and 2 (usage error or no project.md).
#
# HERMETIC: each case runs in a throwaway git repo (mktemp -d) with its own
# .claude/project.md.
#
# Usage: bash tests/bin/test-flow-project-fact.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The project.md lines hold literal backticks, so single quotes are on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-project-fact"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1
REPO="$TMPROOT/repo"
git init -q "$REPO" >/dev/null 2>&1
mkdir -p "$REPO/sub/dir"
cd "$REPO" || exit 1

# expect <label> <want-exit> <want-stdout> <args...>
expect() {
    local label="$1" want_exit="$2" want_out="$3" out status
    shift 3
    out="$("$SCRIPT" "$@" 2>/dev/null)"
    status=$?
    if [ "$status" -eq "$want_exit" ] && [ "$out" = "$want_out" ]; then
        pass "$label"
    else
        fail "$label" "exit: $status (want $want_exit)" "stdout: [$out] (want [$want_out])"
    fi
}

project_md_write "$REPO" \
    'test: `docker compose exec -u www-data app composer test:full`' \
    'plans: `docs/plans`' \
    'release_notes: `docs/releases/RELEASE_NOTES_{version}.md`' \
    'deploy: see docs/development/DEPLOYMENT.md' \
    'private_paths: `docs/plans _noupload`' \
    'plans_extra: `other`'
printf '  - indented: `kept`\n- plans: `second`\n' >> .claude/project.md

expect "value between backticks, spaces kept" 0 'docker compose exec -u www-data app composer test:full' test
expect "a key is matched whole, not as a prefix" 0 'docs/plans' plans
expect "a key with a longer name has its own value" 0 'other' plans_extra
expect "the {version} text is kept as is" 0 'docs/releases/RELEASE_NOTES_{version}.md' release_notes
expect "no backticks: the text after the colon" 0 'see docs/development/DEPLOYMENT.md' deploy
expect "a space-separated list is one value" 0 'docs/plans _noupload' private_paths
expect "an indented list line is found" 0 'kept' indented
expect "the first of two lines for a key wins" 0 'docs/plans' plans
expect "an absent key exits 1 with no output" 1 '' vault
expect "a key that is only a prefix of another is absent" 1 '' plan

# --file prints the path of project.md
expect "--file prints the path" 0 "$(cd "$REPO" && pwd -P)/.claude/project.md" --file

# Run from a subdirectory: the file is found at the repo root.
OUT_SUB="$(cd "$REPO/sub/dir" && "$SCRIPT" plans 2>/dev/null)"
if [ "$OUT_SUB" = "docs/plans" ]; then
    pass "run from a subdirectory: project.md found at the repo root"
else
    fail "run from a subdirectory: project.md found at the repo root" "stdout: [$OUT_SUB]"
fi

# Usage errors.
expect "no argument exits 2" 2 ''
expect "two arguments exit 2" 2 '' plans test
expect "an empty key exits 2" 2 '' ""
expect "a key with a bad character exits 2" 2 '' 'pl.ns'

# A message on stderr for each exit 2.
ERR_BAD="$("$SCRIPT" 'a b' 2>&1 >/dev/null)"
if [[ "$ERR_BAD" == *"has a character other than"* ]]; then
    pass "a bad key prints the reason on stderr"
else
    fail "a bad key prints the reason on stderr" "stderr: [$ERR_BAD]"
fi

# No project.md.
rm -f .claude/project.md
expect "no project.md exits 2" 2 '' plans
ERR_MISSING="$("$SCRIPT" plans 2>&1 >/dev/null)"
if [[ "$ERR_MISSING" == *"project.md is missing"* ]]; then
    pass "no project.md prints the reason on stderr"
else
    fail "no project.md prints the reason on stderr" "stderr: [$ERR_MISSING]"
fi

# Not in a git repo.
NOGIT="$TMPROOT/nogit"
mkdir -p "$NOGIT"
OUT_NOGIT="$(cd "$NOGIT" && GIT_CEILING_DIRECTORIES="$TMPROOT" "$SCRIPT" plans 2>&1)"
STATUS_NOGIT=$?
if [ "$STATUS_NOGIT" -eq 2 ] && [[ "$OUT_NOGIT" == *"not in a git repository"* ]]; then
    pass "outside a git repo exits 2"
else
    fail "outside a git repo exits 2" "exit: $STATUS_NOGIT (want 2)" "output: [$OUT_NOGIT]"
fi

harness_report
