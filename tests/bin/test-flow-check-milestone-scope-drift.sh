#!/bin/bash
#
# Tests for flow-check-milestone-scope-drift: the release-notes
# "Issues Resolved" issue set against the milestone's current membership.
#
# HERMETIC: a stub `gh` goes first on PATH. It accepts only the exact argv
# the script must send (endpoint with state=all and per_page=100,
# --paginate, and the exact --jq filter) and exits 99 on anything else. It
# then runs that --jq filter with the real `jq` over a JSON fixture, so the
# pull-request filter is exercised, not copied. The fixture holds one JSON
# array per "page", the way `gh api --paginate` concatenates them.
# STUB_GH_FAIL=1 makes the stub fail like an auth or network error. Each case
# runs the script from a temp directory that holds its own
# docs/releases/RELEASE_NOTES_<version>.md fixture. No network calls.
#
# Usage: bash tests/bin/test-flow-check-milestone-scope-drift.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The project.md lines hold literal backticks, so single quotes are on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_SCRIPT="$REAL_REPO/plugins/flow/bin/flow-check-milestone-scope-drift"
if [ ! -x "$CHECK_SCRIPT" ]; then
    echo "FAIL: $CHECK_SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1

STUBDIR="$TMPROOT/bin"
WORKDIR="$TMPROOT/repo"
mkdir -p "$STUBDIR" "$WORKDIR/docs/releases"
git init -q "$WORKDIR" >/dev/null 2>&1
project_md_write "$WORKDIR" 'release_notes: `docs/releases/RELEASE_NOTES_{version}.md`'
STUB_MEMBERS_FILE="$TMPROOT/members.txt"
export STUB_MEMBERS_FILE

cat > "$STUBDIR/gh" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "repo" ]; then
    [ "${STUB_REPO_FAIL:-0}" = "1" ] && { echo "gh: simulated repo failure (stub)" >&2; exit 1; }
    echo "example-org/example-repo"
    exit 0
fi
if [ "${STUB_GH_FAIL:-0}" = "1" ]; then
    echo "gh: simulated API failure (stub)" >&2
    exit 1
fi
want_jq='.[] | select(.pull_request == null) | "\(.number)\t\(.state)\t\(.title)"'
want_ep="repos/example-org/example-repo/issues?milestone=${STUB_MILESTONE:-7}&state=all&per_page=100"
if [ "$#" -ne 5 ] || [ "$1" != "api" ] || [ "$2" != "--paginate" ] \
    || [ "$3" != "$want_ep" ] || [ "$4" != "--jq" ] || [ "$5" != "$want_jq" ]; then
    echo "stub gh: unexpected argv: $*" >&2
    exit 99
fi
jq -r "$5" "$STUB_MEMBERS_FILE"
STUB
chmod +x "$STUBDIR/gh"

VERSION="v9.9.9"
NOTES="$WORKDIR/docs/releases/RELEASE_NOTES_${VERSION}.md"

# Writes a release-notes fixture whose "Issues Resolved" section lists the
# given issue numbers. #1895 appears only as a cross-reference inside the
# first bullet, and #4242 only in another section, so neither may count.
write_notes() {
    {
        echo "# Example Project ${VERSION} Release Notes"
        echo ""
        echo "## User-Facing Changes"
        echo ""
        echo "- Something shipped ([#4242](https://github.com/example-org/example-repo/issues/4242))."
        echo ""
        echo "## Issues Resolved"
        echo ""
        local first=1 n
        for n in "$@"; do
            if [ "$first" -eq 1 ]; then
                echo "- [#${n}](https://github.com/example-org/example-repo/issues/${n}) — Entry. Deferred to [#1895](https://github.com/example-org/example-repo/issues/1895)."
                first=0
            else
                echo "- [#${n}](https://github.com/example-org/example-repo/issues/${n}) — Entry."
            fi
        done
        echo ""
        echo "## Deployment Notes"
        echo ""
        echo "See [#4343](https://github.com/example-org/example-repo/issues/4343)."
    } > "$NOTES"
}

# Stages the stub's membership as two JSON "pages": page 1 holds one pull
# request (#9001, which the script's filter must drop) and the first issue;
# page 2 holds the rest. Each issue is closed with title "Title N".
issue_json() { printf '{"number":%s,"state":"closed","title":"Title %s"}' "$1" "$1"; }
write_members() {
    local page1='{"number":9001,"state":"closed","title":"A PR","pull_request":{"url":"x"}}'
    local page2="" n
    if [ "$#" -gt 0 ]; then
        page1="${page1},$(issue_json "$1")"
        shift
    fi
    for n in "$@"; do
        page2="${page2:+${page2},}$(issue_json "$n")"
    done
    printf '[%s]\n[%s]\n' "$page1" "$page2" > "$STUB_MEMBERS_FILE"
}

run_check() {
    (cd "$WORKDIR" && PATH="$STUBDIR:$PATH" "$CHECK_SCRIPT" "$@")
}

# --- Case 1: exact match -> 0 ---------------------------------------------
write_notes 101 102 103
write_members 103 101 102
OUT1="$(run_check "$VERSION" 7 2>&1)"
STATUS1=$?
if [ "$STATUS1" -eq 0 ] && printf '%s' "$OUT1" | grep -q 'Milestone scope matches release notes — 3 issues\.'; then
    pass "Case 1: exact match (cross-reference and other-section links ignored) -> exit 0"
else
    fail "Case 1: exact match (cross-reference and other-section links ignored) -> exit 0" \
        "exit: $STATUS1 (want 0)" "output: [$OUT1]"
fi

# --- Case 2: in release notes, not in membership -> 1, "moved out" ---------
write_notes 101 102 103
write_members 101 102
OUT2="$(run_check "$VERSION" 7 2>&1)"
STATUS2=$?
if [ "$STATUS2" -eq 1 ] \
    && printf '%s' "$OUT2" | grep -q '#103 — moved out of milestone since release notes were written' \
    && ! printf '%s' "$OUT2" | grep -q 'added to milestone'; then
    pass "Case 2: issue in release notes only -> exit 1, reported as moved out"
else
    fail "Case 2: issue in release notes only -> exit 1, reported as moved out" \
        "exit: $STATUS2 (want 1)" "output: [$OUT2]"
fi

# --- Case 3: in membership, not in release notes -> 1, "added" -------------
write_notes 101 102
write_members 101 102 104
OUT3="$(run_check "$VERSION" 7 2>&1)"
STATUS3=$?
if [ "$STATUS3" -eq 1 ] \
    && printf '%s' "$OUT3" | grep -q '#104 — added to milestone, missing from release notes (closed: Title 104)' \
    && ! printf '%s' "$OUT3" | grep -q 'moved out'; then
    pass "Case 3: issue in membership only -> exit 1, reported as added, missing from release notes"
else
    fail "Case 3: issue in membership only -> exit 1, reported as added, missing from release notes" \
        "exit: $STATUS3 (want 1)" "output: [$OUT3]"
fi

# --- Case 4: both directions at once -> 1, both reported -------------------
write_notes 101 102 103
write_members 101 102 104
OUT4="$(run_check "$VERSION" 7 2>&1)"
STATUS4=$?
if [ "$STATUS4" -eq 1 ] \
    && printf '%s' "$OUT4" | grep -q '#103 — moved out of milestone' \
    && printf '%s' "$OUT4" | grep -q '#104 — added to milestone, missing from release notes'; then
    pass "Case 4: mismatch in both directions -> exit 1, both reported"
else
    fail "Case 4: mismatch in both directions -> exit 1, both reported" \
        "exit: $STATUS4 (want 1)" "output: [$OUT4]"
fi

# --- Case 5: release notes file missing -> 2 -------------------------------
rm -f "$NOTES"
write_members 101
OUT5="$(run_check "$VERSION" 7 2>&1)"
STATUS5=$?
if [ "$STATUS5" -eq 2 ] && printf '%s' "$OUT5" | grep -q 'No release notes at'; then
    pass "Case 5: release notes file missing -> exit 2"
else
    fail "Case 5: release notes file missing -> exit 2" "exit: $STATUS5 (want 2)" "output: [$OUT5]"
fi

# --- Case 6: gh api call fails -> 2 ----------------------------------------
write_notes 101
OUT6="$(cd "$WORKDIR" && STUB_GH_FAIL=1 PATH="$STUBDIR:$PATH" "$CHECK_SCRIPT" "$VERSION" 7 2>&1)"
STATUS6=$?
if [ "$STATUS6" -eq 2 ] && printf '%s' "$OUT6" | grep -q 'simulated API failure'; then
    pass "Case 6: gh api call fails -> exit 2, gh's error shown"
else
    fail "Case 6: gh api call fails -> exit 2, gh's error shown" "exit: $STATUS6 (want 2)" "output: [$OUT6]"
fi

# --- Case 7: no Issues Resolved entries -> 2, not "everything added" -------
write_notes
write_members 101 102
OUT7="$(run_check "$VERSION" 7 2>&1)"
STATUS7=$?
if [ "$STATUS7" -eq 2 ] && printf '%s' "$OUT7" | grep -q 'No "- \[#N\]'; then
    pass "Case 7: no Issues Resolved entries -> exit 2"
else
    fail "Case 7: no Issues Resolved entries -> exit 2" "exit: $STATUS7 (want 2)" "output: [$OUT7]"
fi

# --- Case 8: bad arguments -> 2 --------------------------------------------
write_notes 101
write_members 101
OUT8A="$(run_check "$VERSION" 2>&1)"
STATUS8A=$?
OUT8B="$(run_check "$VERSION" abc 2>&1)"
STATUS8B=$?
if [ "$STATUS8A" -eq 2 ] && [ "$STATUS8B" -eq 2 ]; then
    pass "Case 8: missing or non-numeric milestone number -> exit 2"
else
    fail "Case 8: missing or non-numeric milestone number -> exit 2" \
        "exit (missing): $STATUS8A (want 2)" "exit (non-numeric): $STATUS8B (want 2)" \
        "output: [$OUT8A] [$OUT8B]"
fi

# --- Case 9: mixed-width numbers, exact match -> 0 -------------------------
# Numeric sort fed to `comm` misreports these; lexical sort must be used.
write_notes 95 999 2300
write_members 2300 95 999
OUT9="$(run_check "$VERSION" 7 2>&1)"
STATUS9=$?
if [ "$STATUS9" -eq 0 ] && printf '%s' "$OUT9" | grep -q '— 3 issues\.'; then
    pass "Case 9: mixed-width issue numbers, exact match -> exit 0"
else
    fail "Case 9: mixed-width issue numbers, exact match -> exit 0" \
        "exit: $STATUS9 (want 0)" "output: [$OUT9]"
fi

# --- Case 10: mixed-width numbers, mismatch -> 1, no false lines -----------
write_notes 999 2300
write_members 2300 2301
OUT10="$(run_check "$VERSION" 7 2>&1)"
STATUS10=$?
if [ "$STATUS10" -eq 1 ] \
    && printf '%s' "$OUT10" | grep -q '#999 — moved out' \
    && printf '%s' "$OUT10" | grep -q '#2301 — added' \
    && ! printf '%s' "$OUT10" | grep -q '#2300 '; then
    pass "Case 10: mixed-width mismatch -> exit 1, only #999 and #2301 reported"
else
    fail "Case 10: mixed-width mismatch -> exit 1, only #999 and #2301 reported" \
        "exit: $STATUS10 (want 1)" "output: [$OUT10]"
fi

# --- Case 11: milestone has no issues (only a PR) -> 2 ---------------------
write_notes 101
write_members
OUT11="$(run_check "$VERSION" 7 2>&1)"
STATUS11=$?
if [ "$STATUS11" -eq 2 ] && printf '%s' "$OUT11" | grep -q 'has no issues in any state'; then
    pass "Case 11: empty milestone (PR filtered out) -> exit 2"
else
    fail "Case 11: empty milestone (PR filtered out) -> exit 2" \
        "exit: $STATUS11 (want 2)" "output: [$OUT11]"
fi

# --- Case 12: a real bullet in a later "## " section is not counted -------
write_notes 101
printf '%s\n' "- [#4444](https://github.com/example-org/example-repo/issues/4444) — later section." >> "$NOTES"
write_members 101
OUT12="$(run_check "$VERSION" 7 2>&1)"
STATUS12=$?
if [ "$STATUS12" -eq 0 ]; then
    pass "Case 12: bullet under a later section is ignored -> exit 0"
else
    fail "Case 12: bullet under a later section is ignored -> exit 0" \
        "exit: $STATUS12 (want 0)" "output: [$OUT12]"
fi

# --- Case 13: "### Issues Resolved" (wrong level) -> 2 ---------------------
write_notes 101
sed -i.bak 's/^## Issues Resolved$/### Issues Resolved/' "$NOTES" && rm -f "$NOTES.bak"
write_members 101
OUT13="$(run_check "$VERSION" 7 2>&1)"
STATUS13=$?
if [ "$STATUS13" -eq 2 ]; then
    pass "Case 13: wrong heading level for Issues Resolved -> exit 2"
else
    fail "Case 13: wrong heading level for Issues Resolved -> exit 2" \
        "exit: $STATUS13 (want 2)" "output: [$OUT13]"
fi

# --- Case 14: duplicate entries collapse -> 0 with the right count ---------
write_notes 101 102 101
write_members 101 102
OUT14="$(run_check "$VERSION" 7 2>&1)"
STATUS14=$?
if [ "$STATUS14" -eq 0 ] && printf '%s' "$OUT14" | grep -q '— 2 issues\.'; then
    pass "Case 14: duplicate notes entry collapses -> exit 0, 2 issues"
else
    fail "Case 14: duplicate notes entry collapses -> exit 0, 2 issues" \
        "exit: $STATUS14 (want 0)" "output: [$OUT14]"
fi

# --- Case 15: the stub rejects a changed gh call (guards the stub itself) --
write_notes 101
write_members 101
OUT15="$(cd "$WORKDIR" && STUB_MILESTONE=8 PATH="$STUBDIR:$PATH" "$CHECK_SCRIPT" "$VERSION" 7 2>&1)"
STATUS15=$?
if [ "$STATUS15" -eq 2 ] && printf '%s' "$OUT15" | grep -q 'unexpected argv'; then
    pass "Case 15: stub rejects an argv it does not expect -> script exit 2"
else
    fail "Case 15: stub rejects an argv it does not expect -> script exit 2" \
        "exit: $STATUS15 (want 2)" "output: [$OUT15]"
fi

# --- Case 16: closed issue whose entry still has WIP: -> 1, WIP line only -
# The WIP entry counts as an entry, so #102 is not "added ... missing".
# The sed drops the "## Deployment Notes" tail, so the appended bullet
# lands under "## Issues Resolved".
write_notes 101
sed -i.bak '/^## Deployment Notes$/,$d' "$NOTES" && rm -f "$NOTES.bak"
printf '%s\n' "- WIP: [#102](https://github.com/example-org/example-repo/issues/102) — Entry." >> "$NOTES"
write_members 101 102
OUT16="$(run_check "$VERSION" 7 2>&1)"
STATUS16=$?
if [ "$STATUS16" -eq 1 ] \
    && printf '%s' "$OUT16" | grep -q '#102 — still has WIP prefix in release notes' \
    && ! printf '%s' "$OUT16" | grep -q 'added to milestone' \
    && ! printf '%s' "$OUT16" | grep -q 'moved out' \
    && [ "$(printf '%s\n' "$OUT16" | grep -c '#102')" -eq 1 ]; then
    pass "Case 16: closed issue with WIP entry -> exit 1, one WIP line, not reported as missing"
else
    fail "Case 16: closed issue with WIP entry -> exit 1, one WIP line, not reported as missing" \
        "exit: $STATUS16 (want 1)" "output: [$OUT16]"
fi

# --- Case 17: only WIP entries -> counted as entries, not exit 2 ---------
write_notes
sed -i.bak '/^## Deployment Notes$/,$d' "$NOTES" && rm -f "$NOTES.bak"
printf '%s\n' "- WIP: [#101](https://github.com/example-org/example-repo/issues/101) — Entry." >> "$NOTES"
write_members 101 103
OUT17="$(run_check "$VERSION" 7 2>&1)"
STATUS17=$?
if [ "$STATUS17" -eq 1 ] \
    && printf '%s' "$OUT17" | grep -q '#101 — still has WIP prefix' \
    && printf '%s' "$OUT17" | grep -q '#103 — added to milestone' \
    && ! printf '%s' "$OUT17" | grep -q '#101 — added'; then
    pass "Case 17: only WIP entries -> exit 1, WIP and added lines"
else
    fail "Case 17: only WIP entries -> exit 1, WIP and added lines" \
        "exit: $STATUS17 (want 1)" "output: [$OUT17]"
fi

# --- Case 18: no release_notes key -> exit 10, one line on stderr ----------
project_md_write "$WORKDIR" 'test: `make test`'
OUT18="$(run_check "$VERSION" 7 2>&1 >/dev/null)"
STATUS18=$?
if [ "$STATUS18" -eq 10 ] \
    && [ "$OUT18" = "flow-check-milestone-scope-drift: no 'release_notes' key in .claude/project.md. Step skipped." ]; then
    pass "Case 18: no release_notes key -> exit 10, one line on stderr"
else
    fail "Case 18: no release_notes key -> exit 10, one line on stderr" \
        "exit: $STATUS18 (want 10)" "stderr: [$OUT18]"
fi

# --- Case 19: no project.md -> exit 2 --------------------------------------
rm -f "$WORKDIR/.claude/project.md"
run_check "$VERSION" 7 >/dev/null 2>&1
STATUS19=$?
if [ "$STATUS19" -eq 2 ]; then
    pass "Case 19: no project.md -> exit 2"
else
    fail "Case 19: no project.md -> exit 2" "exit: $STATUS19 (want 2)"
fi

# --- Case 20: flow-repo cannot resolve the repo -> exit 2 ------------------
project_md_write "$WORKDIR" 'release_notes: `docs/releases/RELEASE_NOTES_{version}.md`'
write_notes 101
write_members 101
OUT20="$(STUB_REPO_FAIL=1 run_check "$VERSION" 7 2>&1)"
STATUS20=$?
if [ "$STATUS20" -eq 2 ] && printf '%s' "$OUT20" | grep -q 'flow-repo'; then
    pass "Case 20: a repo that gh cannot resolve -> exit 2"
else
    fail "Case 20: a repo that gh cannot resolve -> exit 2" \
        "exit: $STATUS20 (want 2)" "output: [$OUT20]"
fi

harness_report
