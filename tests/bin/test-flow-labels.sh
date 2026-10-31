#!/bin/bash
#
# Tests for plugins/flow/bin/flow-labels: it lists the missing labels, creates
# only those, and never changes a label that exists.
#
# HERMETIC: a throwaway git repo and the shared gh stub. The STUB_EXTRA hook
# fakes `gh label list` and `gh label create`.
#
# Usage: bash tests/bin/test-flow-labels.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/gh-stub.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-labels"
TEMPLATE="$REAL_REPO/plugins/flow/templates/labels.tsv"

TMPROOT="$(mktemp -d)" || exit 1
gh_stub_install "$TMPROOT/bin"
export PATH="$TMPROOT/bin:$PATH"
export STUB_REPO="example-org/example-repo"

REPO="$TMPROOT/repo"
git init -q "$REPO" >/dev/null 2>&1
cd "$REPO" || exit 1

# The fake repo's labels, one name per line. `gh label create` appends here.
export LABELS_FILE="$TMPROOT/labels.txt"
export CREATE_LOG="$TMPROOT/created.txt"
cat > "$TMPROOT/extra" <<'XTRA'
#!/bin/bash
[ "${1:-}" = "label" ] || exit 3
case "${2:-}" in
    list)
        jq -R -s 'split("\n") | map(select(length > 0) | {name: .}) | .[].name' -r < "$LABELS_FILE"
        exit 0
        ;;
    create)
        printf '%s\n' "$3" >> "$LABELS_FILE"
        printf '%s\n' "$*" >> "$CREATE_LOG"
        exit 0
        ;;
esac
exit 3
XTRA
chmod +x "$TMPROOT/extra"
export STUB_EXTRA="$TMPROOT/extra"

WANT_COUNT="$(grep -cvE '^(#|[[:space:]]*$)' "$TEMPLATE")"

# Case 1: a repo with only GitHub's default labels (different case on one).
printf 'BUG\nenhancement\ndocumentation\n' > "$LABELS_FILE"
OUT="$("$SCRIPT" --missing)"
rc=$?
GOT="$(printf '%s\n' "$OUT" | grep -c .)"
if [ "$rc" -eq 1 ] && [ "$GOT" -eq $((WANT_COUNT - 2)) ] && ! printf '%s' "$OUT" | grep -qiE '^(bug|enhancement)'$'\t'; then
    pass "missing lists all labels except existing ones, case-insensitive"
else
    fail "missing lists all labels except existing ones" "rc: $rc (want 1)" "count: $GOT (want $((WANT_COUNT - 2)))"
fi

if printf '%s\n' "$OUT" | grep -qF "$(printf 'component: security\td62728\t')"; then
    pass "a name with a space keeps its color column"
else
    fail "a name with a space keeps its color column" "out: [$OUT]"
fi

# Case 2: create adds only the missing ones, with color and description.
: > "$CREATE_LOG"
"$SCRIPT" --create >/dev/null
rc=$?
CREATED="$(grep -c . "$CREATE_LOG")"
if [ "$rc" -eq 0 ] && [ "$CREATED" -eq $((WANT_COUNT - 2)) ] \
    && grep -qF 'label create signal:defect --repo example-org/example-repo --color b70b81' "$CREATE_LOG" \
    && ! grep -qiE 'label create (bug|enhancement) ' "$CREATE_LOG"; then
    pass "create makes only the missing labels, with repo and color"
else
    fail "create makes only the missing labels" "rc: $rc" "created: $CREATED (want $((WANT_COUNT - 2)))" "log: [$(cat "$CREATE_LOG")]"
fi

# Case 3: after create, nothing is missing, and a second create does nothing.
"$SCRIPT" --missing >/dev/null
rc=$?
: > "$CREATE_LOG"
OUT2="$("$SCRIPT" --create)"
if [ "$rc" -eq 0 ] && [ ! -s "$CREATE_LOG" ] && [[ "$OUT2" == *"no label is missing"* ]]; then
    pass "after create, nothing is missing and create is a no-op"
else
    fail "after create, nothing is missing" "missing rc: $rc" "log: [$(cat "$CREATE_LOG")]"
fi

# Case 3b: a long label list with each match near the top. The list is
# larger than a pipe buffer, so a pipe into `grep -q` gets EPIPE when grep
# exits at the first match. Under pipefail that made a label read as missing.
{
    grep -vE '^(#|[[:space:]]*$)' "$TEMPLATE" | cut -f1
    awk 'BEGIN { for (i = 0; i < 20000; i++) printf "filler-label-%05d\n", i }'
} > "$LABELS_FILE"
OUT3="$("$SCRIPT" --missing 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$OUT3" ]; then
    pass "a long label list finds each label (no pipe into grep -q)"
else
    fail "a long label list finds each label" "rc: $rc (want 0)" "out: [$(printf '%s' "$OUT3" | head -3)]"
fi

# Case 4: gh fails -> exit 2.
STUB_GH_FAIL=1 "$SCRIPT" --missing >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "gh failure -> exit 2"; else fail "gh failure -> exit 2"; fi

"$SCRIPT" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "no argument -> usage error"; else fail "no argument -> usage error"; fi

harness_report
