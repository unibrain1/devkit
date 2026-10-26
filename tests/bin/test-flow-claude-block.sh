#!/bin/bash
#
# Tests for plugins/flow/bin/flow-claude-block: status, diff, and apply of
# the flow block in CLAUDE.md. Text outside the markers must never change.
#
# HERMETIC: each case runs in a throwaway git repo (mktemp -d).
#
# Usage: bash tests/bin/test-flow-claude-block.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-claude-block"
TEMPLATE="$REAL_REPO/plugins/flow/templates/claude-block.md"
REV="$(sed -nE '1s/^<!-- flow:begin rev ([0-9]+) -->$/\1/p' "$TEMPLATE")"

TMPROOT="$(mktemp -d)" || exit 1
REPO="$TMPROOT/repo"
git init -q "$REPO" >/dev/null 2>&1
cd "$REPO" || exit 1

# status_is <label> <want-exit> <want-stdout>
status_is() {
    local out rc
    out="$("$SCRIPT" --status 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq "$2" ] && [ "$out" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "exit: $rc (want $2)" "stdout: [$out] (want [$3])"
    fi
}

if [ -n "$REV" ]; then
    pass "template first line has a revision"
else
    fail "template first line has a revision" "first line: [$(head -n1 "$TEMPLATE")]"
fi

status_is "no CLAUDE.md -> 1" 1 "no CLAUDE.md"

"$SCRIPT" --apply >/dev/null
if cmp -s CLAUDE.md "$TEMPLATE"; then
    pass "apply with no CLAUDE.md creates it from the template"
else
    fail "apply with no CLAUDE.md creates it from the template"
fi
status_is "after apply -> current" 0 "current"

printf '# Project\n\nIntro text.\n' > CLAUDE.md
status_is "CLAUDE.md with no block -> missing" 1 "missing"
DIFF="$("$SCRIPT" --diff)"
if printf '%s' "$DIFF" | grep -q "^+<!-- flow:begin rev ${REV} -->$" && [ "$(cat CLAUDE.md)" = "$(printf '# Project\n\nIntro text.')" ]; then
    pass "diff shows the new block and does not write"
else
    fail "diff shows the new block and does not write" "diff: [$DIFF]"
fi
"$SCRIPT" --apply >/dev/null
if [ "$(head -n3 CLAUDE.md)" = "$(printf '# Project\n\nIntro text.')" ] && grep -q "^<!-- flow:begin rev ${REV} -->$" CLAUDE.md; then
    pass "apply appends the block and keeps the text"
else
    fail "apply appends the block and keeps the text"
fi

{
    printf '# Project\n\nBefore.\n\n'
    printf '<!-- flow:begin rev 0 -->\nold block text\n<!-- flow:end -->\n'
    printf '\n## After\n\nAfter text.\n'
} > CLAUDE.md
status_is "old block -> old" 1 "old (rev 0, current rev ${REV})"
"$SCRIPT" --apply >/dev/null
if ! grep -q 'old block text' CLAUDE.md \
    && [ "$(head -n3 CLAUDE.md)" = "$(printf '# Project\n\nBefore.')" ] \
    && [ "$(tail -n3 CLAUDE.md)" = "$(printf '## After\n\nAfter text.')" ] \
    && [ "$(grep -c '^<!-- flow:begin' CLAUDE.md)" -eq 1 ]; then
    pass "apply replaces an old block in place and keeps the text around it"
else
    fail "apply replaces an old block in place and keeps the text around it" "file: [$(cat CLAUDE.md)]"
fi
status_is "after replace -> current" 0 "current"

printf '<!-- flow:begin rev 1 -->\nno end\n' > CLAUDE.md
"$SCRIPT" --status >/dev/null 2>&1
assert_rc=$?
BEFORE="$(cat CLAUDE.md)"
"$SCRIPT" --apply >/dev/null 2>&1
apply_rc=$?
if [ "$assert_rc" -eq 2 ] && [ "$apply_rc" -eq 2 ] && [ "$(cat CLAUDE.md)" = "$BEFORE" ]; then
    pass "a begin with no end -> exit 2, no write"
else
    fail "a begin with no end -> exit 2, no write" "status rc: $assert_rc, apply rc: $apply_rc"
fi

"$SCRIPT" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "no argument -> usage error"; else fail "no argument -> usage error"; fi

# A CLAUDE.md link to a file outside the repo must never be written.
OUTSIDE="$TMPROOT/outside.txt"
printf 'keep me\n' > "$OUTSIDE"
rm -f CLAUDE.md
ln -s "$OUTSIDE" CLAUDE.md
"$SCRIPT" --apply >/dev/null 2>&1
link_rc=$?
if [ "$link_rc" -eq 2 ] && [ "$(cat "$OUTSIDE")" = "keep me" ] && [ -L CLAUDE.md ]; then
    pass "CLAUDE.md symlink -> exit 2, target not written"
else
    fail "CLAUDE.md symlink -> exit 2, target not written" "rc: $link_rc" "target: [$(cat "$OUTSIDE")]"
fi
rm -f CLAUDE.md
if ! ls .CLAUDE.md.flow.* >/dev/null 2>&1; then
    pass "no temp file left in the repo"
else
    fail "no temp file left in the repo"
fi

harness_report
