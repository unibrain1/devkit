#!/bin/bash
#
# Tests for flow-release-hotfix: the next patch tag, the annotated tag on the
# merge commit, the GitHub release with --latest or --draft, the stops, the
# resume path, and --dry-run.
#
# HERMETIC: each case builds a bare "origin" repo and a working clone under
# a temp dir. Real git runs against them, so every push goes to the temp
# bare repo. The shared stub `gh` (tests/lib/gh-stub.sh) goes first on PATH.
# It answers `repo view` and `pr view` from a fixture. Its STUB_EXTRA
# handler keeps the release state in a file. Each gh call goes to a log, and
# the cases check the log. No network calls. Never touches this repo's
# branches, tags, or remotes.
#
# Usage: bash tests/bin/test-flow-release-hotfix.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The project.md lines hold literal backticks, so single quotes are on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/gh-stub.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-release-hotfix"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1

# A GIT_DIR or GIT_WORK_TREE from the caller would send the fixture's git
# commands to the caller's repo, not to $TMPROOT.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

export GIT_AUTHOR_NAME="test-release-hotfix"
export GIT_AUTHOR_EMAIL="test-release-hotfix@localhost"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

PR=57
REPO_NAME="example-org/example-repo"

STUBDIR="$TMPROOT/bin"
gh_stub_install "$STUBDIR" || exit 1
export STUB_EXTRA="$TMPROOT/gh-extra"
cat > "$STUB_EXTRA" <<'STUB'
#!/bin/bash
# Exit 3: the call is not for this handler. The shared stub goes on.
# State files in $STUB_STATE: release.<tag> (the release exists; it holds
# the create arguments), fail_release (release create fails), view_error
# (release view prints this text and fails), view_out (release view prints
# this text and succeeds), milestones.json (the open
# milestones; [] when absent), fail_milestones (the milestones call fails).
S="$STUB_STATE"
case "$*" in
    "release view "*)
        if [ -f "$S/view_error" ]; then
            cat "$S/view_error" >&2
            exit 1
        fi
        [ -f "$S/release.$3" ] || { echo "release not found" >&2; exit 1; }
        # The script asks for isDraft. A release made with --draft is a draft.
        if [ -f "$S/view_out" ]; then cat "$S/view_out"; exit 0; fi
        if grep -q -- '--draft' "$S/release.$3"; then echo true; else echo false; fi ;;
    "release create "*)
        if [ -f "$S/fail_release" ]; then
            echo "stub gh: simulated release create failure" >&2
            exit 1
        fi
        echo "$*" > "$S/release.$3" ;;
    "api repos/"*"/milestones?"*)
        if [ -f "$S/fail_milestones" ]; then
            echo "HTTP 502: simulated milestones failure (stub)" >&2
            exit 1
        fi
        filter="."
        while [ $# -gt 0 ]; do
            [ "$1" = "--jq" ] && filter="$2"
            shift
        done
        if [ -f "$S/milestones.json" ]; then
            jq -r "$filter" "$S/milestones.json"
        else
            echo '[]' | jq -r "$filter"
        fi ;;
    *)
        exit 3 ;;
esac
STUB
chmod +x "$STUB_EXTRA"

# setup_case <name> [project.md line ...]
# Builds a fresh origin and working clone with one commit on main, and sets
# ORIGIN, WORK and STATE. Each extra line goes into project.md.
setup_case() {
    local dir="$TMPROOT/$1"
    shift
    ORIGIN="$dir/origin.git"
    WORK="$dir/work"
    STATE="$dir/state"
    MERGE_SHA=""
    mkdir -p "$STATE"
    git init -q --bare "$ORIGIN"
    git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
    git clone -q "$ORIGIN" "$WORK" 2>/dev/null
    (
        cd "$WORK" || exit 1
        git checkout -q -b main
        echo base > README.md
        project_md_write "$WORK" 'plans: `docs/plans`' "$@"
        git add README.md .claude/project.md
        git commit -q -m base
        git push -q origin main
    ) || exit 1
    : > "$STATE/calls"
}

# add_commit <message>: a commit on main, pushed. Prints its SHA.
add_commit() {
    (
        cd "$WORK" || exit 1
        echo "$1" >> README.md
        git commit -q -am "$1"
        git push -q origin main
        git rev-parse HEAD
    )
}

# add_release <tag>: a commit on main with an annotated tag, both pushed.
add_release() {
    add_commit "release $1" >/dev/null || exit 1
    git -C "$WORK" tag -a "$1" -m "Release $1" || exit 1
    git -C "$WORK" push -q origin "refs/tags/$1" || exit 1
}

# side_commit: a commit on the branch side, pushed. main does not contain
# it. Prints its SHA.
side_commit() {
    (
        cd "$WORK" || exit 1
        git checkout -q -b side
        echo side > side.txt
        git add side.txt
        git commit -q -m side
        git push -q origin side
        git rev-parse HEAD
        git checkout -q main
    )
}

# pr_fixture <state> <base> <merge-sha>
pr_fixture() {
    jq -n --arg s "$1" --arg b "$2" --arg m "$3" \
        '{state: $s, baseRefName: $b, mergeCommit: (if $m == "" then null else {oid: $m} end)}' \
        > "$STATE/pr.json"
}

# merge_hotfix: the hotfix PR merge commit on main, and a MERGED PR fixture.
merge_hotfix() {
    MERGE_SHA="$(add_commit "hotfix")" || exit 1
    pr_fixture MERGED main "$MERGE_SHA"
}

run_hotfix() {
    (cd "$WORK" && PATH="$STUBDIR:$PATH" STUB_STATE="$STATE" STUB_LOG="$STATE/calls" \
        STUB_PR_JSON="$STATE/pr.json" "$SCRIPT" "$@")
}

# origin_tag_commit <tag>: the commit of <tag> on origin, or nothing.
origin_tag_commit() {
    git -C "$ORIGIN" rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null
}

creates() { grep -c '^release create' "$STATE/calls"; }

# check_released <tag> <flag>
# Prints a reason and returns 1 on the first check that fails.
check_released() {
    local tag="$1" flag="$2" want
    [ "$(origin_tag_commit "$tag")" = "$MERGE_SHA" ] || { echo "tag $tag not on origin at the merge commit"; return 1; }
    [ "$(git -C "$ORIGIN" cat-file -t "refs/tags/$tag")" = "tag" ] || { echo "tag $tag is not annotated"; return 1; }
    want="release create $tag --repo $REPO_NAME --verify-tag --generate-notes --title $tag $flag"
    [ "$(creates)" -eq 1 ] || { echo "release create not called exactly once"; return 1; }
    grep -qxF -- "$want" "$STATE/calls" || { echo "no call [$want]"; return 1; }
    if [ "$flag" = "--draft" ] && grep -q -- '--latest' "$STATE/calls"; then
        echo "draft release has --latest"; return 1
    fi
    grep -qxF "pr view $PR --repo $REPO_NAME --json state,baseRefName,mergeCommit --jq .state, .baseRefName, (.mergeCommit.oid // \"\")" "$STATE/calls" \
        || { echo "pr view call not as expected"; return 1; }
    return 0
}

# expect_release <label> <tag> <flag> [args...]: run, want exit 0 and the
# release.
expect_release() {
    local label="$1" tag="$2" flag="$3" out status why
    shift 3
    out="$(run_hotfix "$@" "$PR" 2>&1)"
    status=$?
    why="$(check_released "$tag" "$flag")"
    if [ "$status" -eq 0 ] && [ -z "$why" ]; then
        pass "$label"
    else
        fail "$label" "exit: $status (want 0)" "check: $why" "output: [$out]"
    fi
}

# expect_stop <label> <want-exit> <stderr-text>: run, want the exit code,
# the text, no new tag on origin, and no release create.
expect_stop() {
    local label="$1" want="$2" text="$3" out status tags_before tags_after
    tags_before="$(git -C "$ORIGIN" tag | sort)"
    out="$(run_hotfix "$PR" 2>&1)"
    status=$?
    tags_after="$(git -C "$ORIGIN" tag | sort)"
    if [ "$status" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$text" \
        && [ "$tags_before" = "$tags_after" ] && [ "$(creates)" -eq 0 ]; then
        pass "$label"
    else
        fail "$label" "exit: $status (want $want)" "tags before: [$tags_before] after: [$tags_after]" \
            "release creates: $(creates)" "output: [$out]"
    fi
}

# --- v1.4.0 -> v1.4.1, published (no release key) --------------------------
setup_case basic
add_release v1.4.0
merge_hotfix
expect_release "v1.4.0 -> v1.4.1, annotated tag on the merge commit, --latest" v1.4.1 --latest

# --- Run again: tag and release exist -> no new tag, no create -------------
: > "$STATE/calls"
OUT="$(run_hotfix "$PR" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ "$(creates)" -eq 0 ] && [ "$(origin_tag_commit v1.4.1)" = "$MERGE_SHA" ] \
    && [ -z "$(git -C "$ORIGIN" tag --list v1.4.2)" ] && printf '%s' "$OUT" | grep -q 'Release v1.4.1 exists'; then
    pass "run again: tag and release exist -> exit 0, no v1.4.2, no release create"
else
    fail "run again -> exit 0, no change" "exit: $STATUS creates: $(creates)" "output: [$OUT]"
fi

# --- release: publish -> --latest ------------------------------------------
setup_case publish 'release: `publish`'
add_release v1.4.0
merge_hotfix
expect_release "release: publish -> --latest" v1.4.1 --latest

# --- release: draft -> --draft, no --latest --------------------------------
setup_case draft 'release: `draft`'
add_release v1.4.0
merge_hotfix
expect_release "release: draft -> --draft and no --latest" v1.4.1 --draft

# --- Numeric sort; 4-part, prerelease, and side-branch tags do not count ----
setup_case sort
add_release v1.9.0
add_release v1.10.0
add_release v1.10.0.1
add_release v1.11.0-rc1
git -C "$WORK" tag -a v2.0.0 "$(side_commit)" -m side && git -C "$WORK" push -q origin refs/tags/v2.0.0
merge_hotfix
expect_release "v1.9.0, v1.10.0, v1.10.0.1, v1.11.0-rc1, v2.0.0 off main -> v1.10.1" v1.10.1 --latest

# --- A bad release value -> exit 2 before any change ----------------------
setup_case badrelease 'release: `later`'
add_release v1.4.0
merge_hotfix
expect_stop "release: later -> exit 2, no tag" 2 "Allowed values: publish, draft"
if [ ! -s "$STATE/calls" ]; then
    pass "release: later -> no gh call"
else
    fail "release: later -> no gh call" "calls: [$(cat "$STATE/calls")]"
fi

# --- milestone/v1.4.1 on origin -> exit 1 ----------------------------------
setup_case collision
add_release v1.4.0
git -C "$WORK" push -q origin main:refs/heads/milestone/v1.4.1
merge_hotfix
expect_stop "milestone/v1.4.1 on origin -> exit 1, no tag" 1 "milestone/v1.4.1 exists on origin"

# --- The tag exists on origin at another commit -> exit 1 ----------------
setup_case othertag
add_release v1.4.0
git -C "$WORK" tag -a v1.4.1 "$(side_commit)" -m other && git -C "$WORK" push -q origin refs/tags/v1.4.1
SIDE_SHA="$(origin_tag_commit v1.4.1)"
merge_hotfix
expect_stop "v1.4.1 on origin at another commit -> exit 1" 1 "not at the merge commit"
if [ "$(origin_tag_commit v1.4.1)" = "$SIDE_SHA" ]; then
    pass "v1.4.1 at another commit -> the tag on origin does not move"
else
    fail "v1.4.1 at another commit -> the tag on origin does not move"
fi

# --- Resume: the tag push completed, release create failed ---------------
setup_case resume
add_release v1.4.0
merge_hotfix
touch "$STATE/fail_release"
OUT="$(run_hotfix "$PR" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 1 ] && [ "$(origin_tag_commit v1.4.1)" = "$MERGE_SHA" ] && [ ! -f "$STATE/release.v1.4.1" ]; then
    pass "resume 1: release create fails -> exit 1, tag pushed, no release"
else
    fail "resume 1: release create fails -> exit 1" "exit: $STATUS (want 1)" "output: [$OUT]"
fi
rm -f "$STATE/fail_release"
TAG_OBJ="$(git -C "$ORIGIN" rev-parse refs/tags/v1.4.1)"
: > "$STATE/calls"
expect_release "resume 2: tag on origin, no release -> creates the release" v1.4.1 --latest
if [ "$(git -C "$ORIGIN" rev-parse refs/tags/v1.4.1)" = "$TAG_OBJ" ] && [ -z "$(git -C "$ORIGIN" tag --list v1.4.2)" ]; then
    pass "resume 2: the tag is the same tag object, no v1.4.2"
else
    fail "resume 2: the tag is the same tag object, no v1.4.2"
fi

# --- Resume: the tag is local only, at the merge commit -> push it --------
setup_case localtag
add_release v1.4.0
merge_hotfix
git -C "$WORK" tag -a v1.4.1 "$MERGE_SHA" -m "Hotfix v1.4.1"
expect_release "local tag at the merge commit -> pushed, release created" v1.4.1 --latest

# --- A release exists, the tag is on origin -> no create -----------------
setup_case relexists
add_release v1.4.0
merge_hotfix
git -C "$WORK" tag -a v1.4.1 "$MERGE_SHA" -m "Hotfix v1.4.1" && git -C "$WORK" push -q origin refs/tags/v1.4.1
echo "made earlier" > "$STATE/release.v1.4.1"
OUT="$(run_hotfix "$PR" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ "$(creates)" -eq 0 ] && grep -q '^release view v1.4.1 ' "$STATE/calls"; then
    pass "release exists -> exit 0, no release create"
else
    fail "release exists -> exit 0, no release create" "exit: $STATUS creates: $(creates)" "output: [$OUT]"
fi

# --- No vX.Y.Z tag on main -> exit 2 ---------------------------------------
setup_case notag
add_release v1.0.0.1
add_release v1.1.0-rc1
merge_hotfix
expect_stop "no vX.Y.Z tag on main (only 4-part and rc) -> exit 2" 2 "no vX.Y.Z tag"

# --- PR not merged -> exit 1 ------------------------------------------------
setup_case open
add_release v1.4.0
merge_hotfix
pr_fixture OPEN main ""
expect_stop "PR OPEN -> exit 1, no tag" 1 "must be MERGED with base main"

# --- PR base not main -> exit 1 ---------------------------------------------
setup_case base
add_release v1.4.0
merge_hotfix
pr_fixture MERGED milestone/v1.5.0 "$MERGE_SHA"
expect_stop "PR base milestone/v1.5.0 -> exit 1, no tag" 1 "must be MERGED with base main"

# --- Merge commit not on origin/main -> exit 1 -----------------------------
setup_case offmain
add_release v1.4.0
pr_fixture MERGED main "$(side_commit)"
expect_stop "merge commit not on origin/main -> exit 1, no tag" 1 "is not on origin/main"

# --- --dry-run -> prints the commands, changes nothing ---------------------
setup_case dryrun
add_release v1.4.0
merge_hotfix
OUT="$(run_hotfix --dry-run "$PR" 2>&1)"
STATUS=$?
WHY=""
[ "$STATUS" -eq 0 ] || WHY="exit $STATUS (want 0)"
[ -z "$(git -C "$ORIGIN" tag --list v1.4.1)" ] || WHY="$WHY; tag on origin"
[ -z "$(git -C "$WORK" tag --list v1.4.1)" ] || WHY="$WHY; local tag"
[ "$(creates)" -eq 0 ] || WHY="$WHY; release create ran"
for line in "[dry-run] git tag -a v1.4.1 $MERGE_SHA -m Hotfix v1.4.1" \
    "[dry-run] git push origin refs/tags/v1.4.1" \
    "[dry-run] gh release create v1.4.1 --repo $REPO_NAME --verify-tag --generate-notes --title v1.4.1 --latest"; do
    printf '%s\n' "$OUT" | grep -qxF -- "$line" || WHY="$WHY; no line [$line]"
done
if [ -z "$WHY" ]; then
    pass "--dry-run -> exit 0, prints tag, push and release create, changes nothing"
else
    fail "--dry-run -> changes nothing" "$WHY" "output: [$OUT]"
fi

# --- A milestone release tag on the merge commit -> exit 1 ----------------
setup_case milestonetag
add_release v1.2.0
merge_hotfix
git -C "$WORK" tag -a v1.3.0 "$MERGE_SHA" -m "Release v1.3.0: x" && git -C "$WORK" push -q origin refs/tags/v1.3.0
expect_stop "Release v1.3.0 tag on the merge commit -> exit 1, no tag, no release" 1 "not a hotfix merge"
if ! grep -q '^release ' "$STATE/calls"; then
    pass "Release v1.3.0 tag on the merge commit -> no release call"
else
    fail "Release v1.3.0 tag on the merge commit -> no release call" "calls: [$(cat "$STATE/calls")]"
fi

# --- release view fails with an auth error -> exit 1 before the tag push ---
setup_case viewerror
add_release v1.4.0
merge_hotfix
echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" > "$STATE/view_error"
expect_stop "release view HTTP 401 -> exit 1, no tag pushed" 1 "HTTP 401: Bad credentials"
if [ -z "$(git -C "$WORK" tag --list v1.4.1)" ]; then
    pass "release view HTTP 401 -> no local tag"
else
    fail "release view HTTP 401 -> no local tag"
fi
: > "$STATE/calls"
OUT="$(run_hotfix --dry-run "$PR" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 1 ] && printf '%s' "$OUT" | grep -qF "HTTP 401" && ! printf '%s' "$OUT" | grep -qF '[dry-run]'; then
    pass "--dry-run, release view HTTP 401 -> exit 1, no plan printed"
else
    fail "--dry-run, release view HTTP 401 -> exit 1" "exit: $STATUS (want 1)" "output: [$OUT]"
fi

# --- A draft release exists and the release key is publish -> exit 1 ------
setup_case draftpublish
add_release v1.4.0
merge_hotfix
echo "release create v1.4.1 --draft" > "$STATE/release.v1.4.1"
expect_stop "draft release v1.4.1, release: publish -> exit 1, no tag" 1 "exists as a draft"

# --- release view succeeds with output other than true or false -> exit 1 --
setup_case viewodd
add_release v1.4.0
merge_hotfix
echo "release create v1.4.1 --draft" > "$STATE/release.v1.4.1"
printf 'warning: something\ntrue\n' > "$STATE/view_out"
expect_stop "release view prints an unexpected isDraft -> exit 1, no tag" 1 "cannot read the draft state"

# --- A draft release exists and the release key is draft -> skip create ----
setup_case draftdraft 'release: `draft`'
add_release v1.4.0
merge_hotfix
echo "release create v1.4.1 --draft" > "$STATE/release.v1.4.1"
: > "$STATE/calls"
OUT="$(run_hotfix "$PR" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ "$(creates)" -eq 0 ] && [ -n "$(git -C "$ORIGIN" tag --list v1.4.1)" ]; then
    pass "draft release v1.4.1, release: draft -> tag pushed, no create"
else
    fail "draft release v1.4.1, release: draft -> tag pushed, no create" "exit: $STATUS (want 0)" "output: [$OUT]"
fi

# --- An open milestone with the next version -> exit 1 --------------------
setup_case openmilestone
add_release v1.4.0
merge_hotfix
echo '[{"title":"v1.5.0: Later"},{"title":"v1.4.1: Something"}]' > "$STATE/milestones.json"
expect_stop "open milestone 'v1.4.1: Something' -> exit 1, no tag" 1 "the open milestone 'v1.4.1: Something' has the version v1.4.1"
if grep -qxF "api repos/$REPO_NAME/milestones?state=open&per_page=100 --jq .[].title" "$STATE/calls"; then
    pass "open milestone check -> gh api call as expected"
else
    fail "open milestone check -> gh api call as expected" "calls: [$(cat "$STATE/calls")]"
fi
echo '[{"title":"v1.4.1"}]' > "$STATE/milestones.json"
: > "$STATE/calls"
expect_stop "open milestone 'v1.4.1' -> exit 1, no tag" 1 "has the version v1.4.1"
echo '[{"title":"v1.4.1 Something"}]' > "$STATE/milestones.json"
: > "$STATE/calls"
expect_stop "open milestone 'v1.4.1 Something' -> exit 1, no tag" 1 "the open milestone 'v1.4.1 Something' has the version v1.4.1"

# --- The milestones call fails -> exit 1 -----------------------------------
setup_case milestonefail
add_release v1.4.0
merge_hotfix
touch "$STATE/fail_milestones"
expect_stop "milestones call fails -> exit 1, no tag" 1 "cannot read the open milestones"

# --- Open milestones v1.4.10 and v1.4.1x do not block v1.4.1 -------------
setup_case othermilestone
add_release v1.4.0
merge_hotfix
echo '[{"title":"v1.4.10: x"},{"title":"v1.4.1x"},{"title":"v1.4.1.1"}]' > "$STATE/milestones.json"
expect_release "open milestones v1.4.10, v1.4.1x, v1.4.1.1 -> v1.4.1 released" v1.4.1 --latest

# --- Resume skips the milestone check -------------------------------------
setup_case resumemilestone
add_release v1.4.0
merge_hotfix
git -C "$WORK" tag -a v1.4.1 "$MERGE_SHA" -m "Hotfix v1.4.1" && git -C "$WORK" push -q origin refs/tags/v1.4.1
echo '[{"title":"v1.4.1: Something"}]' > "$STATE/milestones.json"
expect_release "Hotfix v1.4.1 on the merge commit, open milestone v1.4.1 -> release created" v1.4.1 --latest
if ! grep -q '/milestones' "$STATE/calls"; then
    pass "resume -> no milestones call"
else
    fail "resume -> no milestones call" "calls: [$(cat "$STATE/calls")]"
fi

# --- A stale local-only tag does not count --------------------------------
setup_case staletag
add_release v1.4.0
git -C "$WORK" tag -a v1.5.0 -m "Release v1.5.0" HEAD
merge_hotfix
expect_release "local-only tag v1.5.0 on main -> v1.4.1, not v1.5.1" v1.4.1 --latest
if [ -z "$(git -C "$ORIGIN" tag --list v1.5.1)" ]; then
    pass "local-only tag v1.5.0 -> no v1.5.1 on origin"
else
    fail "local-only tag v1.5.0 -> no v1.5.1 on origin"
fi

# --- A second hotfix after v1.4.1 -> v1.4.2 --------------------------------
setup_case second
add_release v1.4.0
merge_hotfix
expect_release "first hotfix -> v1.4.1" v1.4.1 --latest
FIRST_SHA="$MERGE_SHA"
merge_hotfix
: > "$STATE/calls"
expect_release "second hotfix on a later commit -> v1.4.2" v1.4.2 --latest
if [ "$(origin_tag_commit v1.4.1)" = "$FIRST_SHA" ]; then
    pass "second hotfix -> v1.4.1 does not move"
else
    fail "second hotfix -> v1.4.1 does not move"
fi

# --- git merge-base fails with an error -> exit 1, own message ------------
setup_case mergebaseerror
add_release v1.4.0
merge_hotfix
GITSTUB="$TMPROOT/gitstub"
mkdir -p "$GITSTUB"
REAL_GIT="$(command -v git)"
cat > "$GITSTUB/git" <<GITSTUB_EOF
#!/bin/bash
if [ "\$1" = "merge-base" ]; then
    echo "fatal: simulated merge-base error (stub)" >&2
    exit 128
fi
exec "$REAL_GIT" "\$@"
GITSTUB_EOF
chmod +x "$GITSTUB/git"
OUT="$(cd "$WORK" && PATH="$GITSTUB:$STUBDIR:$PATH" STUB_STATE="$STATE" STUB_LOG="$STATE/calls" \
    STUB_PR_JSON="$STATE/pr.json" "$SCRIPT" "$PR" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 1 ] && printf '%s' "$OUT" | grep -qF "git merge-base failed (status 128)" \
    && ! printf '%s' "$OUT" | grep -qF "is not on origin/main" && [ -z "$(git -C "$ORIGIN" tag --list v1.4.1)" ]; then
    pass "git merge-base error -> exit 1, error message, not 'not on origin/main'"
else
    fail "git merge-base error -> exit 1" "exit: $STATUS (want 1)" "output: [$OUT]"
fi

# --- The merge commit does not contain the last tag -> exit 1 -------------
# A wrong PR number, or a later hotfix tagged first.
setup_case olderpr
add_release v1.4.0
merge_hotfix
LATER_SHA="$(add_commit "later hotfix")"
git -C "$WORK" tag -a v1.4.1 "$LATER_SHA" -m "Hotfix v1.4.1" && git -C "$WORK" push -q origin refs/tags/v1.4.1
expect_stop "merge commit older than the last tag v1.4.1 -> exit 1, no v1.4.2" 1 "does not contain the last tag v1.4.1"

# --- A local-only tag at another commit -> exit 1 --------------------------
setup_case localother
add_release v1.4.0
git -C "$WORK" tag -a v1.4.1 "$(side_commit)" -m x
merge_hotfix
expect_stop "local-only tag v1.4.1 at another commit -> exit 1" 1 "local tag v1.4.1 is at"
if [ -z "$(origin_tag_commit v1.4.1)" ]; then
    pass "local-only tag v1.4.1 at another commit -> not pushed"
else
    fail "local-only tag v1.4.1 at another commit -> not pushed"
fi

# --- flow-repo fails -> exit 1 before any gh call --------------------------
setup_case repofail
add_release v1.4.0
merge_hotfix
BINCOPY="$TMPROOT/bincopy"
cp -R "$REAL_REPO/plugins/flow/bin" "$BINCOPY"
printf '#!/bin/bash\necho "flow-repo: simulated failure (stub)" >&2\nexit 1\n' > "$BINCOPY/flow-repo"
chmod +x "$BINCOPY/flow-repo"
OUT="$(cd "$WORK" && PATH="$STUBDIR:$PATH" STUB_STATE="$STATE" STUB_LOG="$STATE/calls" \
    STUB_PR_JSON="$STATE/pr.json" "$BINCOPY/flow-release-hotfix" "$PR" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 1 ] && ! grep -q '^pr view' "$STATE/calls" \
    && [ -z "$(git -C "$ORIGIN" tag --list v1.4.1)" ]; then
    pass "flow-repo fails -> exit 1, no pr view, no tag"
else
    fail "flow-repo fails -> exit 1" "exit: $STATUS (want 1)" "calls: [$(cat "$STATE/calls")]" "output: [$OUT]"
fi

# --- /bin/bash (3.2 on macOS): a first run prints no failure message -------
# bash 3.2 runs the ERR trap inside a command substitution. "release not
# found" on a first run must not print the trap message.
if [ -x /bin/bash ]; then
    setup_case systembash
    add_release v1.4.0
    merge_hotfix
    OUT="$(cd "$WORK" && PATH="$STUBDIR:$PATH" STUB_STATE="$STATE" STUB_LOG="$STATE/calls" \
        STUB_PR_JSON="$STATE/pr.json" /bin/bash "$SCRIPT" "$PR" 2>&1)"
    STATUS=$?
    WHY="$(check_released v1.4.1 --latest)"
    if [ "$STATUS" -eq 0 ] && [ -z "$WHY" ] && ! printf '%s' "$OUT" | grep -qF 'a command failed'; then
        pass "/bin/bash first run -> released, no failure message"
    else
        fail "/bin/bash first run -> released, no failure message" "exit: $STATUS (want 0)" "check: $WHY" "output: [$OUT]"
    fi
fi

# --- Bad arguments -> exit 2 before any gh call ----------------------------
setup_case args
add_release v1.4.0
merge_hotfix
for args in "" "--dry-run" "abc" "#57" "57 58" "--force 57" "--dry-run 57 58"; do
    : > "$STATE/calls"
    # Word splitting of $args is on purpose: each case is a list of args.
    # shellcheck disable=SC2086
    OUT="$(cd "$WORK" && PATH="$STUBDIR:$PATH" STUB_STATE="$STATE" STUB_LOG="$STATE/calls" \
        STUB_PR_JSON="$STATE/pr.json" "$SCRIPT" $args 2>&1)"
    STATUS=$?
    if [ "$STATUS" -eq 2 ] && [ ! -s "$STATE/calls" ] && printf '%s' "$OUT" | grep -qF 'Usage: flow-release-hotfix'; then
        pass "args [$args] -> exit 2, usage, no gh call"
    else
        fail "args [$args] -> exit 2" "exit: $STATUS calls: [$(cat "$STATE/calls")]" "output: [$OUT]"
    fi
done
if [ -z "$(git -C "$ORIGIN" tag --list v1.4.1)" ]; then
    pass "bad arguments -> no tag"
else
    fail "bad arguments -> no tag"
fi

harness_report
