#!/bin/bash
#
# Tests for flow-release-milestone: the full release run, and the
# resume path after the script stops part way.
#
# HERMETIC: each case builds a bare "origin" repo and a working clone under
# a temp dir. Real git runs against them, so every push goes to the temp
# bare repo. The shared stub `gh` (tests/lib/gh-stub.sh) goes first on
# PATH. Its STUB_EXTRA handler keeps the PR, release and milestone state in
# files, and does the PR merge with real git in a scratch clone of the temp
# origin. The shared stub answers `repo view` and fails any other call.
# No network calls. Never touches this repo's branches, tags, or remotes.
#
# Usage: bash tests/bin/test-flow-release-milestone.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The project.md lines hold literal backticks, so single quotes are on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/gh-stub.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-release-milestone"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1

export GIT_AUTHOR_NAME="test-release-milestone"
export GIT_AUTHOR_EMAIL="test-release-milestone@localhost"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

VERSION="v9.9.9"
PR=42
MS=7
NOTES_REL="docs/releases/RELEASE_NOTES_${VERSION}.md"
KEEP_REL="docs/plans/releases/${VERSION}-release-notes.md"
NOTES_TEXT="Release notes body for ${VERSION}."

STUBDIR="$TMPROOT/bin"
gh_stub_install "$STUBDIR" || exit 1
export STUB_EXTRA="$TMPROOT/gh-extra"
cat > "$STUB_EXTRA" <<'STUB'
#!/bin/bash
# Exit 3: the call is not for this handler. The shared stub goes on.
#
# State files in $STUB_STATE: pr_state, mergeable, merge_sha, calls,
# release_notes (present once the release exists), release_flag (--latest
# or --draft, from release create), milestone_state, fail_release
# (present -> release create fails), push_after_merge (present -> one more
# commit lands on main right after the merge), pr_head (the PR head saved
# at merge time, after which the branch is gone), local_delete_fail
# (present -> pr merge merges, then fails to delete the local branch and
# keeps the remote branch, as real gh can).
# Protection answers: linear_classic (classic protection requires linear
# history), linear_ruleset (a ruleset requires it), protection_403 (the
# classic read fails with HTTP 403), not_protected (the classic read fails
# with HTTP 404 "Branch not protected"), protection_upgrade (both reads
# fail with the HTTP 403 "Upgrade to GitHub Pro" that a private repo on the
# GitHub Free plan gets), rules_fail (the rules read fails with a generic
# HTTP 403), rules_count_12 (the rules hold 12 required_linear_history
# rules, so the real jq gives a count of 12), rules_garbage (the rules read
# succeeds with exit 0 and prints abc, not a count), rules_empty (the rules
# read succeeds with exit 0 and prints nothing), gh_warning (both reads
# succeed with a valid answer and also print a warning line on stderr).
# With none of these, classic protection exists with linear
# history off, and no ruleset applies.
S="$STUB_STATE"
echo "$*" >> "$S/calls"
want_pr="${STUB_PR:-42}"
linear=0
{ [ -f "$S/linear_classic" ] || [ -f "$S/linear_ruleset" ]; } && linear=1
case "$*" in
    "pr view $want_pr --json state --jq .state")
        cat "$S/pr_state" ;;
    "pr view $want_pr --json mergeable --jq .mergeable")
        cat "$S/mergeable" ;;
    "pr view $want_pr --json mergeCommit --jq .mergeCommit.oid")
        cat "$S/merge_sha" ;;
    "pr view $want_pr --json headRefOid --jq .headRefOid")
        # GitHub keeps headRefOid after the merge deletes the branch.
        if [ -f "$S/pr_head" ]; then
            cat "$S/pr_head"
            exit 0
        fi
        git --git-dir="$STUB_ORIGIN" rev-parse "refs/heads/milestone/v9.9.9"
        # push_after_head_check: a commit lands right after this answer,
        # before the script pulls (the race that the second check closes).
        if [ -f "$S/push_after_head_check" ]; then
            rm -rf "$S/racer"
            git clone -q "$STUB_ORIGIN" "$S/racer" || exit 1
            (
                cd "$S/racer" || exit 1
                git checkout -q milestone/v9.9.9
                echo race > race.txt
                git add race.txt
                git commit -q -m "commit during the release"
                git push -q origin milestone/v9.9.9
            ) || exit 1
        fi ;;
    "api repos/example-org/example-repo/branches/main/protection --jq "*)
        # Real gh prints the error body on stdout and the message on stderr.
        if [ -f "$S/protection_403" ]; then
            printf '{"message":"Resource not accessible by integration","status":"403"}'
            echo "gh: Resource not accessible by integration (HTTP 403)" >&2
            exit 1
        fi
        if [ -f "$S/protection_upgrade" ]; then
            printf '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","documentation_url":"https://docs.github.com/rest","status":"403"}'
            echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >&2
            exit 1
        fi
        if [ -f "$S/not_protected" ]; then
            printf '{"message":"Branch not protected","status":"404"}'
            echo "gh: Branch not protected (HTTP 404)" >&2
            exit 1
        fi
        enabled=false
        [ -f "$S/linear_classic" ] && enabled=true
        [ -f "$S/gh_warning" ] && echo "A new release of gh is available" >&2
        # The real jq runs the script's filter, as real gh does.
        printf '{"required_linear_history":{"enabled":%s}}' "$enabled" | jq -r "$4" ;;
    "api repos/example-org/example-repo/rules/branches/main --jq "*)
        if [ -f "$S/protection_upgrade" ]; then
            printf '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","documentation_url":"https://docs.github.com/rest","status":"403"}'
            echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >&2
            exit 1
        fi
        if [ -f "$S/rules_fail" ]; then
            printf '{"message":"Resource not accessible by integration","status":"403"}'
            echo "gh: Resource not accessible by integration (HTTP 403)" >&2
            exit 1
        fi
        if [ -f "$S/rules_garbage" ]; then
            printf 'abc'
            exit 0
        fi
        [ -f "$S/rules_empty" ] && exit 0
        [ -f "$S/gh_warning" ] && echo "A new release of gh is available" >&2
        rules='[{"type":"deletion","ruleset_id":1}]'
        if [ -f "$S/rules_count_12" ]; then
            rules='[{"type":"deletion","ruleset_id":1}'
            for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
                rules="$rules"',{"type":"required_linear_history","ruleset_id":2}'
            done
            rules="$rules]"
        fi
        [ -f "$S/linear_ruleset" ] && rules='[{"type":"deletion","ruleset_id":1},{"type":"required_linear_history","ruleset_id":2}]'
        printf '%s' "$rules" | jq -r "$4" ;;
    "pr merge $want_pr --"*" --delete-branch --match-head-commit "*)
        method="$4"
        case "$method" in
            --merge|--squash) ;;
            *) exit 3 ;;
        esac
        if [ "$method" = "--merge" ] && [ "$linear" -eq 1 ]; then
            echo "GraphQL: Merge commits are not allowed on this repository. (mergePullRequest)" >&2
            exit 1
        fi
        # Real gh refuses the merge when the head moved. Do the same.
        all_args="$*"
        want_head="${all_args##* }"
        have_head="$(git --git-dir="$STUB_ORIGIN" rev-parse "refs/heads/milestone/v9.9.9")"
        if [ "$want_head" != "$have_head" ]; then
            echo "stub gh: head is $have_head, not $want_head" >&2
            exit 1
        fi
        # GitHub keeps the PR head under refs/pull/<N>/head after the merge.
        git --git-dir="$STUB_ORIGIN" update-ref "refs/pull/$want_pr/head" "$have_head" || exit 1
        rm -rf "$S/merger"
        git clone -q "$STUB_ORIGIN" "$S/merger" || exit 1
        (
            cd "$S/merger" || exit 1
            git checkout -q main
            if [ "$method" = "--squash" ]; then
                git merge -q --squash "origin/milestone/v9.9.9" >/dev/null || exit 1
                git commit -q -m "Release v9.9.9 (#$want_pr)" || exit 1
            else
                git merge -q --no-ff -m "Merge pull request #$want_pr" "origin/milestone/v9.9.9" || exit 1
            fi
            git push -q origin main || exit 1
            git rev-parse HEAD > "$S/merge_sha"
            if [ -f "$S/push_after_merge" ]; then
                echo later > later.txt
                git add later.txt
                git commit -q -m "commit after the merge"
                git push -q origin main || exit 1
            fi
        ) || exit 1
        echo "$have_head" > "$S/pr_head"
        echo MERGED > "$S/pr_state"
        # Real gh --delete-branch deletes the local branch first, then the
        # remote branch. When the local delete fails, gh exits non-zero
        # after the merge and the remote branch stays.
        if [ -f "$S/local_delete_fail" ]; then
            echo "failed to delete local branch milestone/v9.9.9: simulated (stub)" >&2
            exit 1
        fi
        if git rev-parse -q --verify "refs/heads/milestone/v9.9.9" >/dev/null; then
            git branch -D milestone/v9.9.9 >/dev/null || exit 1
        fi
        git --git-dir="$STUB_ORIGIN" update-ref -d "refs/heads/milestone/v9.9.9" || exit 1 ;;
    "api repos/example-org/example-repo/milestones/7 --jq .title")
        echo "v9.9.9: Test milestone" ;;
    "api repos/example-org/example-repo/milestones/7 -X PATCH -f state=closed")
        [ -f "$S/close_ignored" ] || echo closed > "$S/milestone_state" ;;
    "api repos/example-org/example-repo/milestones/7 --jq .state")
        cat "$S/milestone_state" 2>/dev/null || echo open ;;
    "release view v9.9.9 --repo example-org/example-repo")
        [ -f "$S/release_notes" ] || exit 1 ;;
    "release create v9.9.9 --repo example-org/example-repo --title example-repo v9.9.9 --notes-file "*" --verify-tag --latest" \
    | "release create v9.9.9 --repo example-org/example-repo --title example-repo v9.9.9 --notes-file "*" --verify-tag --draft")
        if [ -f "$S/fail_release" ]; then
            echo "stub gh: simulated release create failure" >&2
            exit 1
        fi
        args="$*"
        notes="${args#*--notes-file }"
        notes="${notes%% --verify-tag*}"
        cp "$notes" "$S/release_notes"
        echo "${args##* }" > "$S/release_flag" ;;
    *)
        exit 3 ;;
esac
STUB
chmod +x "$STUB_EXTRA"

# A git wrapper that fails `git show` when FAIL_GIT_SHOW is set, fails
# `git branch -D` when FAIL_GIT_BRANCH_D is set, and runs the real git for
# everything else.
REAL_GIT="$(command -v git)"
GITSTUBDIR="$TMPROOT/gitbin"
mkdir -p "$GITSTUBDIR"
cat > "$GITSTUBDIR/git" <<STUB
#!/bin/bash
if [ "\$1" = show ] && [ -n "\${FAIL_GIT_SHOW:-}" ]; then
    echo "stub git: simulated show failure" >&2
    exit 128
fi
if [ "\$1" = branch ] && [ "\$2" = -D ] && [ -n "\${FAIL_GIT_BRANCH_D:-}" ]; then
    echo "stub git: simulated branch delete failure" >&2
    exit 1
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$GITSTUBDIR/git"

# setup_case <name> [project.md line ...]
# Builds a fresh origin, working clone and stub state for one case, and
# sets ORIGIN, WORK and STATE. Each extra line goes into project.md.
setup_case() {
    local dir="$TMPROOT/$1"
    shift
    ORIGIN="$dir/origin.git"
    WORK="$dir/work"
    STATE="$dir/state"
    mkdir -p "$STATE"
    git init -q --bare "$ORIGIN"
    git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
    git clone -q "$ORIGIN" "$WORK" 2>/dev/null
    (
        cd "$WORK" || exit 1
        git checkout -q -b main
        echo base > README.md
        project_md_write "$WORK" \
            'release_notes: `docs/releases/RELEASE_NOTES_{version}.md`' \
            'plans: `docs/plans`' "$@"
        git add README.md .claude/project.md
        git commit -q -m base
        git push -q origin main
        git checkout -q -b "milestone/${VERSION}"
        mkdir -p docs/releases
        echo "$NOTES_TEXT" > "$NOTES_REL"
        echo feature > feature.txt
        git add "$NOTES_REL" feature.txt
        git commit -q -m "milestone work"
        git push -q origin "milestone/${VERSION}"
    ) || exit 1
    echo OPEN > "$STATE/pr_state"
    echo MERGEABLE > "$STATE/mergeable"
    : > "$STATE/calls"
}

run_release() {
    (cd "$WORK" && PATH="$STUBDIR:$PATH" STUB_STATE="$STATE" STUB_ORIGIN="$ORIGIN" "$SCRIPT" "$@")
}

# check_released [release-flag]
# Checks the end state of a completed release. The release must come from
# release create with <release-flag> (default --latest: no release key).
# Prints a reason and returns 1 on the first check that fails.
check_released() {
    local want_flag="${1:---latest}" tag_sha merge_sha
    [ "$(cat "$STATE/pr_state")" = "MERGED" ] || { echo "PR not merged"; return 1; }
    [ "$(grep -c '^pr merge' "$STATE/calls")" -eq 1 ] || { echo "pr merge not called exactly once"; return 1; }
    grep -qE '^pr merge .* --match-head-commit [0-9a-f]{40}$' "$STATE/calls" || { echo "pr merge without --match-head-commit"; return 1; }
    [ "$(cat "$STATE/release_notes" 2>/dev/null)" = "$NOTES_TEXT" ] || { echo "release notes content wrong"; return 1; }
    [ "$(cat "$STATE/release_flag" 2>/dev/null)" = "$want_flag" ] || { echo "release not created with $want_flag"; return 1; }
    [ "$(cat "$STATE/milestone_state" 2>/dev/null)" = "closed" ] || { echo "milestone not closed"; return 1; }
    tag_sha="$(git -C "$ORIGIN" rev-parse "${VERSION}^{commit}" 2>/dev/null)" || { echo "tag not on origin"; return 1; }
    merge_sha="$(cat "$STATE/merge_sha")"
    [ "$tag_sha" = "$merge_sha" ] || { echo "tag not on merge commit"; return 1; }
    git -C "$ORIGIN" cat-file -e "main:${NOTES_REL}" 2>/dev/null && { echo "notes file still on main"; return 1; }
    [ ! -e "$WORK/$KEEP_REL" ] || { echo "saved notes copy not removed"; return 1; }
    return 0
}

# --- Case 1: full run -> 0 ------------------------------------------------
setup_case case1
OUT1="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUS1=$?
WHY1="$(check_released)"
if [ "$STATUS1" -eq 0 ] && [ -z "$WHY1" ]; then
    pass "Case 1: full run -> exit 0, merged, tagged, released, milestone closed"
else
    fail "Case 1: full run -> exit 0" "exit: $STATUS1 (want 0)" "check: $WHY1" "output: [$OUT1]"
fi

# --- Case 2: stop after notes removal, then resume -> 0 ------------------
# The first run removes and pushes the notes, then stops on "not
# mergeable". The saved copy is deleted too, so the resume must restore it
# from history.
setup_case case2
echo CONFLICTING > "$STATE/mergeable"
OUT2A="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUS2A=$?
REMOVED_ON_ORIGIN=1
git -C "$ORIGIN" cat-file -e "milestone/${VERSION}:${NOTES_REL}" 2>/dev/null && REMOVED_ON_ORIGIN=0
SAVED_COPY=0
[ "$(cat "$WORK/$KEEP_REL" 2>/dev/null)" = "$NOTES_TEXT" ] && SAVED_COPY=1
if [ "$STATUS2A" -eq 2 ] && [ "$REMOVED_ON_ORIGIN" -eq 1 ] && [ "$SAVED_COPY" -eq 1 ]; then
    pass "Case 2a: not mergeable after removal -> exit 2, removal pushed, notes saved in docs/plans/releases/"
else
    fail "Case 2a: not mergeable after removal -> exit 2" "exit: $STATUS2A (want 2)" \
        "removed on origin: $REMOVED_ON_ORIGIN, saved copy: $SAVED_COPY" "output: [$OUT2A]"
fi
rm -f "$WORK/$KEEP_REL"
echo MERGEABLE > "$STATE/mergeable"
OUT2B="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUS2B=$?
WHY2="$(check_released)"
REMOVALS="$(git -C "$ORIGIN" log --full-history --oneline main -- "$NOTES_REL" | grep -c 'remove v9.9.9 release notes')"
if [ "$STATUS2B" -eq 0 ] && [ -z "$WHY2" ] && [ "$REMOVALS" -eq 1 ] \
    && printf '%s' "$OUT2B" | grep -q 'already removed in'; then
    pass "Case 2b: resume -> exit 0, one removal commit, notes restored from history"
else
    fail "Case 2b: resume -> exit 0" "exit: $STATUS2B (want 0)" "check: $WHY2" \
        "removal commits: $REMOVALS (want 1)" "output: [$OUT2B]"
fi

# --- Case 3: release create fails, then resume -> 0 ----------------------
setup_case case3
touch "$STATE/fail_release"
OUT3A="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUS3A=$?
if [ "$STATUS3A" -eq 2 ] && printf '%s' "$OUT3A" | grep -q 'run the script again'; then
    pass "Case 3a: release create fails after merge and tag -> exit 2 with resume hint"
else
    fail "Case 3a: release create fails -> exit 2" "exit: $STATUS3A (want 2)" "output: [$OUT3A]"
fi
rm -f "$STATE/fail_release" "$WORK/$KEEP_REL"
OUT3B="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUS3B=$?
WHY3="$(check_released)"
if [ "$STATUS3B" -eq 0 ] && [ -z "$WHY3" ] \
    && printf '%s' "$OUT3B" | grep -q 'already merged — skipping' \
    && printf '%s' "$OUT3B" | grep -q "Tag ${VERSION} already exists on the merge commit"; then
    pass "Case 3b: resume -> exit 0, merge and tag skipped, release created from restored notes"
else
    fail "Case 3b: resume -> exit 0" "exit: $STATUS3B (want 0)" "check: $WHY3" "output: [$OUT3B]"
fi

# --- Case 4: second run after a full release -> 0, nothing repeated ------
OUT4="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUS4=$?
if [ "$STATUS4" -eq 0 ] && [ "$(grep -c '^release create' "$STATE/calls")" -eq 2 ] \
    && printf '%s' "$OUT4" | grep -q "Release ${VERSION} already exists"; then
    pass "Case 4: run after a full release -> exit 0, no new merge or release"
else
    fail "Case 4: run after a full release -> exit 0" "exit: $STATUS4 (want 0)" "output: [$OUT4]"
fi

# --- Case 5: notes file never on the branch -> 1 ------------------------
setup_case case5
(
    cd "$WORK" || exit 1
    git checkout -q main
    git branch -q -D "milestone/${VERSION}"
    git checkout -q -b "milestone/${VERSION}"
    echo feature > feature.txt
    git add feature.txt
    git commit -q -m "milestone work without notes"
    git push -q -f origin "milestone/${VERSION}"
) || exit 1
OUT5="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUS5=$?
if [ "$STATUS5" -eq 1 ] && printf '%s' "$OUT5" | grep -q 'no commit on the branch removed it' \
    && ! grep -q '^pr merge' "$STATE/calls"; then
    pass "Case 5: notes file never on the branch -> exit 1, no merge"
else
    fail "Case 5: notes file never on the branch -> exit 1" "exit: $STATUS5 (want 1)" "output: [$OUT5]"
fi

# --- Case 6: a missing project fact -> 2, nothing changes ----------
setup_case case6
BEFORE6="$(git -C "$ORIGIN" for-each-ref)"
project_md_write "$WORK" 'plans: `docs/plans`'
OUT6A="$(run_release "$VERSION" "$PR" "$MS" 2>&1 >/dev/null)"
STATUS6A=$?
project_md_write "$WORK" 'release_notes: `docs/releases/RELEASE_NOTES_{version}.md`'
OUT6B="$(run_release "$VERSION" "$PR" "$MS" 2>&1 >/dev/null)"
STATUS6B=$?
rm -f "$WORK/.claude/project.md"
run_release "$VERSION" "$PR" "$MS" >/dev/null 2>&1
STATUS6C=$?
AFTER6="$(git -C "$ORIGIN" for-each-ref)"
if [ "$STATUS6A" -eq 2 ] && [ "$STATUS6B" -eq 2 ] && [ "$STATUS6C" -eq 2 ] \
    && [ "$OUT6A" = "flow-release-milestone: no 'release_notes' key in .claude/project.md. Add it. This script needs it to release." ] \
    && [ "$OUT6B" = "flow-release-milestone: no 'plans' key in .claude/project.md. Add it. This script needs it to release." ] \
    && [ "$BEFORE6" = "$AFTER6" ] && ! grep -qE '^(pr merge|release create)' "$STATE/calls"; then
    pass "Case 6: no release_notes key -> 2, no plans key -> 2, no project.md -> 2, nothing changed"
else
    fail "Case 6: missing project facts" "exits: $STATUS6A $STATUS6B $STATUS6C (want 2 2 2)" \
        "stderr A: [$OUT6A]" "stderr B: [$OUT6B]"
fi

# --- Case 6b: flow-repo cannot resolve the repo -> 1, nothing changes ------
setup_case case6b
OUT6D="$(STUB_GH_FAIL_REPO_VIEW=1 run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUS6D=$?
if [ "$STATUS6D" -eq 1 ] && printf '%s' "$OUT6D" | grep -q 'flow-repo' \
    && ! grep -qE '^(pr merge|release create)' "$STATE/calls"; then
    pass "Case 6b: a repo that gh cannot resolve -> exit 1, nothing changed"
else
    fail "Case 6b: a repo that gh cannot resolve -> exit 1" "exit: $STATUS6D (want 1)" "output: [$OUT6D]"
fi

# --- Case 6c: an empty project fact -> 2, nothing changes ----------
# An empty plans value would send the notes copy to /releases/.
setup_case case6c
BEFORE6B="$(git -C "$ORIGIN" for-each-ref)"
project_md_write "$WORK" 'release_notes: `docs/releases/RELEASE_NOTES_{version}.md`' 'plans: ``'
OUT6BA="$(run_release "$VERSION" "$PR" "$MS" 2>&1 >/dev/null)"
STATUS6BA=$?
project_md_write "$WORK" 'release_notes: ``' 'plans: `docs/plans`'
OUT6BB="$(run_release "$VERSION" "$PR" "$MS" 2>&1 >/dev/null)"
STATUS6BB=$?
AFTER6B="$(git -C "$ORIGIN" for-each-ref)"
if [ "$STATUS6BA" -eq 2 ] && [ "$STATUS6BB" -eq 2 ] \
    && [ "$OUT6BA" = "flow-release-milestone: the 'plans' key in .claude/project.md is empty. Give it a value. This script needs it to release." ] \
    && [ "$OUT6BB" = "flow-release-milestone: the 'release_notes' key in .claude/project.md is empty. Give it a value. This script needs it to release." ] \
    && [ "$BEFORE6B" = "$AFTER6B" ] && ! grep -qE '^(pr merge|release create)' "$STATE/calls"; then
    pass "Case 6c: empty plans -> 2, empty release_notes -> 2, nothing changed"
else
    fail "Case 6c: empty project fact -> 2" "exits: $STATUS6BA $STATUS6BB (want 2 2)" "plans: [$OUT6BA]" "release_notes: [$OUT6BB]"
fi

# --- Case 7: dry run -> 0, nothing changes -------------------------------
setup_case case7
BEFORE="$(git -C "$ORIGIN" for-each-ref)"
OUT7="$(run_release --dry-run "$VERSION" "$PR" "$MS" 2>&1)"
STATUS7=$?
AFTER="$(git -C "$ORIGIN" for-each-ref)"
if [ "$STATUS7" -eq 0 ] && [ "$BEFORE" = "$AFTER" ] \
    && ! grep -qE '^(pr merge|release create|api .* -X PATCH)' "$STATE/calls" \
    && printf '%s' "$OUT7" | grep -q "\[dry-run\] cp ${NOTES_REL} ${KEEP_REL}"; then
    pass "Case 7: dry run -> exit 0, no ref or gh state change"
else
    fail "Case 7: dry run -> exit 0" "exit: $STATUS7 (want 0)" "output: [$OUT7]"
fi

# --- Case 8: a commit lands on main after the merge -> tag on merge ----
setup_case case8
touch "$STATE/push_after_merge"
OUT8="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUS8=$?
WHY8="$(check_released)"
if [ "$STATUS8" -eq 0 ] && [ -z "$WHY8" ]; then
    pass "Case 8: commit on main after the merge -> exit 0, tag on the merge commit, not HEAD"
else
    fail "Case 8: commit on main after the merge -> tag on merge commit" "exit: $STATUS8 (want 0)" \
        "check: $WHY8" "output: [$OUT8]"
fi

# --- Case 9: local main diverged from origin/main -> 1, no merge ---------
setup_case case9
(
    cd "$WORK" || exit 1
    git checkout -q main
    echo stray > stray.txt
    git add stray.txt
    git commit -q -m "stray local commit"
    git checkout -q "milestone/${VERSION}"
) || exit 1
OTHER="$TMPROOT/case9/other"
git clone -q "$ORIGIN" "$OTHER" 2>/dev/null
(
    cd "$OTHER" || exit 1
    git checkout -q main
    echo remote > remote.txt
    git add remote.txt
    git commit -q -m "remote commit"
    git push -q origin main
) || exit 1
OUT9="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUS9=$?
# Exit 1 means "nothing changed", so the check must run before Step 6
# removes the notes and pushes the milestone branch.
NOTES_ON_ORIGIN9=0
git -C "$ORIGIN" cat-file -e "milestone/${VERSION}:${NOTES_REL}" 2>/dev/null && NOTES_ON_ORIGIN9=1
if [ "$STATUS9" -eq 1 ] && printf '%s' "$OUT9" | grep -q 'commit(s) not on origin/main' \
    && ! grep -q '^pr merge' "$STATE/calls" && [ "$NOTES_ON_ORIGIN9" -eq 1 ]; then
    pass "Case 9: diverged local main -> exit 1 with the stray-commit message, no push, no merge"
else
    fail "Case 9: diverged local main -> exit 1, no push" "exit: $STATUS9 (want 1)" \
        "notes still on origin milestone branch: $NOTES_ON_ORIGIN9 (want 1)" "output: [$OUT9]"
fi

# --- Case 10: notes restore fails -> 2, no empty notes copy --------------
setup_case case10
touch "$STATE/fail_release"
run_release "$VERSION" "$PR" "$MS" >/dev/null 2>&1
rm -f "$STATE/fail_release" "$WORK/$KEEP_REL"
OUT10="$(cd "$WORK" && PATH="$GITSTUBDIR:$STUBDIR:$PATH" FAIL_GIT_SHOW=1 STUB_STATE="$STATE" \
    STUB_ORIGIN="$ORIGIN" "$SCRIPT" "$VERSION" "$PR" "$MS" 2>&1)"
STATUS10=$?
LEFTOVER="$(find "$WORK/docs/plans/releases" -name "${VERSION}-release-notes.md*" 2>/dev/null)"
if [ "$STATUS10" -eq 2 ] && [ -z "$LEFTOVER" ] && [ ! -f "$STATE/release_notes" ] \
    && printf '%s' "$OUT10" | grep -q 'Could not restore'; then
    pass "Case 10: git show fails during restore -> exit 2 with the restore message, no notes copy left behind"
else
    fail "Case 10: git show fails during restore -> exit 2" "exit: $STATUS10 (want 2)" \
        "left behind: [$LEFTOVER]" "output: [$OUT10]"
fi

# --- Case R1: --reviewed-sha is the PR head -> full release -------------
setup_case caseR1
REVIEWED="$(git -C "$ORIGIN" rev-parse "refs/heads/milestone/${VERSION}")"
OUTR1="$(run_release --reviewed-sha "$REVIEWED" "$VERSION" "$PR" "$MS" 2>&1)"
STATUSR1=$?
WHYR1="$(check_released)"
if [ "$STATUSR1" -eq 0 ] && [ -z "$WHYR1" ]; then
    pass "Case R1: reviewed SHA is the head -> released"
else
    fail "Case R1: reviewed SHA is the head" "exit: $STATUSR1 (want 0)" "check: $WHYR1" "output: [$OUTR1]"
fi

# --- Case R2: a commit lands after the review -> exit 1, nothing changes ---
setup_case caseR2
REVIEWED="$(git -C "$ORIGIN" rev-parse "refs/heads/milestone/${VERSION}")"
(
    cd "$WORK" || exit 1
    git checkout -q "milestone/${VERSION}"
    echo late > late.txt
    git add late.txt
    git commit -q -m "late commit after review"
    git push -q origin "milestone/${VERSION}"
    git checkout -q main
)
BEFORER2="$(git -C "$ORIGIN" for-each-ref)"
OUTR2="$(run_release --reviewed-sha "$REVIEWED" "$VERSION" "$PR" "$MS" 2>&1)"
STATUSR2=$?
AFTERR2="$(git -C "$ORIGIN" for-each-ref)"
if [ "$STATUSR2" -eq 1 ] && [ "$BEFORER2" = "$AFTERR2" ] \
    && [[ "$OUTR2" == *"not the reviewed commit"* ]] && ! grep -q '^pr merge' "$STATE/calls"; then
    pass "Case R2: commit after review -> exit 1, nothing pushed or merged"
else
    fail "Case R2: commit after review" "exit: $STATUSR2 (want 1)" "output: [$OUTR2]"
fi

# --- Case R3: rerun after Step 6 pushed the notes removal -> released ----
setup_case caseR3
REVIEWED="$(git -C "$ORIGIN" rev-parse "refs/heads/milestone/${VERSION}")"
echo CONFLICTING > "$STATE/mergeable"
run_release --reviewed-sha "$REVIEWED" "$VERSION" "$PR" "$MS" >/dev/null 2>&1
STATUSR3A=$?
echo MERGEABLE > "$STATE/mergeable"
OUTR3="$(run_release --reviewed-sha "$REVIEWED" "$VERSION" "$PR" "$MS" 2>&1)"
STATUSR3=$?
WHYR3="$(check_released)"
if [ "$STATUSR3A" -eq 2 ] && [ "$STATUSR3" -eq 0 ] && [ -z "$WHYR3" ]; then
    pass "Case R3: rerun with the script's own notes removal on top -> released"
else
    fail "Case R3: rerun after notes removal" "exits: $STATUSR3A $STATUSR3 (want 2 0)" "check: $WHYR3" "output: [$OUTR3]"
fi

# --- Case R4: the milestone does not close -> exit 2 ---------------------
setup_case caseR4
touch "$STATE/close_ignored"
OUTR4="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSR4=$?
if [ "$STATUSR4" -eq 2 ] && [[ "$OUTR4" == *"not 'closed'"* ]]; then
    pass "Case R4: milestone still open after the close call -> exit 2"
else
    fail "Case R4: milestone still open after the close call" "exit: $STATUSR4 (want 2)" "output: [$OUTR4]"
fi

# --- Case R5: a push lands between the head check and the pull -> exit 1 --
setup_case caseR5
REVIEWED="$(git -C "$ORIGIN" rev-parse "refs/heads/milestone/${VERSION}")"
touch "$STATE/push_after_head_check"
OUTR5="$(run_release --reviewed-sha "$REVIEWED" "$VERSION" "$PR" "$MS" 2>&1)"
STATUSR5=$?
RACE_HEAD="$(git -C "$ORIGIN" log -1 --format=%s "refs/heads/milestone/${VERSION}")"
if [ "$STATUSR5" -eq 1 ] && [[ "$OUTR5" == *"after the pull"* ]] \
    && [ "$RACE_HEAD" = "commit during the release" ] && ! grep -q '^pr merge' "$STATE/calls"; then
    pass "Case R5: push during the release -> exit 1 after the pull, nothing pushed or merged"
else
    fail "Case R5: push during the release" "exit: $STATUSR5 (want 1)" "origin head: $RACE_HEAD" "output: [$OUTR5]"
fi

# --- Merge method: main's protection selects --merge or --squash --------

# merge_parents <sha>: prints the number of parents of <sha> in origin.
merge_parents() {
    git -C "$ORIGIN" rev-list --parents -n 1 "$1" | awk '{print NF - 1}'
}

# --- Case M1: main not protected -> --merge ----------------------------
setup_case caseM1
touch "$STATE/not_protected"
OUTM1="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM1=$?
WHYM1="$(check_released)"
if [ "$STATUSM1" -eq 0 ] && [ -z "$WHYM1" ] && grep -q "^pr merge $PR --merge " "$STATE/calls" \
    && [ "$(merge_parents "$(cat "$STATE/merge_sha")")" = "2" ] \
    && [[ "$OUTM1" == *"Merge method: merge (main does not require linear history)"* ]] \
    && [[ "$OUTM1" != *"a command failed"* ]]; then
    pass "Case M1: main not protected -> exit 0, --merge, tag on the merge commit"
else
    fail "Case M1: main not protected -> --merge" "exit: $STATUSM1 (want 0)" "check: $WHYM1" \
        "merge calls: [$(grep '^pr merge' "$STATE/calls")]" "output: [$OUTM1]"
fi

# --- Case M2: classic protection with linear history -> --squash -------
setup_case caseM2
touch "$STATE/linear_classic"
OUTM2="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM2=$?
WHYM2="$(check_released)"
if [ "$STATUSM2" -eq 0 ] && [ -z "$WHYM2" ] && grep -q "^pr merge $PR --squash " "$STATE/calls" \
    && [ "$(merge_parents "$(cat "$STATE/merge_sha")")" = "1" ] \
    && ! git -C "$ORIGIN" cat-file -e "$(cat "$STATE/merge_sha"):docs/releases/RELEASE_NOTES_${VERSION}.md" 2>/dev/null \
    && [[ "$OUTM2" == *"Merge method: squash (main requires linear history)"* ]]; then
    pass "Case M2: classic linear history -> exit 0, --squash, tag on the squash commit, notes not on main"
else
    fail "Case M2: classic linear history -> --squash" "exit: $STATUSM2 (want 0)" "check: $WHYM2" \
        "merge calls: [$(grep '^pr merge' "$STATE/calls")]" "output: [$OUTM2]"
fi

# --- Case M3: a ruleset requires linear history -> --squash ------------
setup_case caseM3
touch "$STATE/linear_ruleset"
OUTM3="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM3=$?
WHYM3="$(check_released)"
if [ "$STATUSM3" -eq 0 ] && [ -z "$WHYM3" ] && grep -q "^pr merge $PR --squash " "$STATE/calls"; then
    pass "Case M3: ruleset with required_linear_history -> exit 0, --squash"
else
    fail "Case M3: ruleset linear history -> --squash" "exit: $STATUSM3 (want 0)" "check: $WHYM3" \
        "merge calls: [$(grep '^pr merge' "$STATE/calls")]" "output: [$OUTM3]"
fi

# --- Case M4: classic protection, linear off, no ruleset -> --merge ----
setup_case caseM4
OUTM4="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM4=$?
WHYM4="$(check_released)"
if [ "$STATUSM4" -eq 0 ] && [ -z "$WHYM4" ] && grep -q "^pr merge $PR --merge " "$STATE/calls" \
    && grep -q "^api repos/example-org/example-repo/branches/main/protection " "$STATE/calls" \
    && grep -q "^api repos/example-org/example-repo/rules/branches/main " "$STATE/calls"; then
    pass "Case M4: protection without linear history, no ruleset -> exit 0, --merge"
else
    fail "Case M4: no linear history -> --merge" "exit: $STATUSM4 (want 0)" "check: $WHYM4" \
        "calls: [$(cat "$STATE/calls")]" "output: [$OUTM4]"
fi

# --- Case M5: protection read fails (403) -> exit 1, nothing changes ----
setup_case caseM5
touch "$STATE/protection_403"
BEFOREM5="$(git -C "$ORIGIN" for-each-ref)"
OUTM5="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM5=$?
AFTERM5="$(git -C "$ORIGIN" for-each-ref)"
if [ "$STATUSM5" -eq 1 ] && [ "$BEFOREM5" = "$AFTERM5" ] \
    && [[ "$OUTM5" == *"cannot read the branch protection or rules of main"* ]] \
    && [[ "$OUTM5" != *"a command failed"* ]] \
    && ! grep -q '^pr merge' "$STATE/calls"; then
    pass "Case M5: protection read fails -> exit 1, no push, no merge, no tag"
else
    fail "Case M5: protection read fails -> exit 1" "exit: $STATUSM5 (want 1)" "output: [$OUTM5]"
fi

# --- Case M6: linear, --reviewed-sha is the head -> --squash, head pinned --
setup_case caseM6
touch "$STATE/linear_classic"
REVIEWED="$(git -C "$ORIGIN" rev-parse "refs/heads/milestone/${VERSION}")"
OUTM6="$(run_release --reviewed-sha "$REVIEWED" "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM6=$?
WHYM6="$(check_released)"
if [ "$STATUSM6" -eq 0 ] && [ -z "$WHYM6" ] \
    && grep -qE "^pr merge $PR --squash --delete-branch --match-head-commit [0-9a-f]{40}\$" "$STATE/calls"; then
    pass "Case M6: linear with the reviewed head -> exit 0, --squash with --match-head-commit"
else
    fail "Case M6: linear with the reviewed head" "exit: $STATUSM6 (want 0)" "check: $WHYM6" \
        "merge calls: [$(grep '^pr merge' "$STATE/calls")]" "output: [$OUTM6]"
fi

# --- Case M7: linear, a push lands between head check and pull -> exit 1 --
setup_case caseM7
touch "$STATE/linear_classic"
REVIEWED="$(git -C "$ORIGIN" rev-parse "refs/heads/milestone/${VERSION}")"
touch "$STATE/push_after_head_check"
OUTM7="$(run_release --reviewed-sha "$REVIEWED" "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM7=$?
RACE_HEADM7="$(git -C "$ORIGIN" log -1 --format=%s "refs/heads/milestone/${VERSION}")"
if [ "$STATUSM7" -eq 1 ] && [[ "$OUTM7" == *"after the pull"* ]] \
    && [ "$RACE_HEADM7" = "commit during the release" ] && ! grep -q '^pr merge' "$STATE/calls"; then
    pass "Case M7: linear, push during the release -> exit 1, nothing pushed or merged"
else
    fail "Case M7: linear, push during the release" "exit: $STATUSM7 (want 1)" \
        "origin head: $RACE_HEADM7" "output: [$OUTM7]"
fi

# --- Case M8: linear, stop after the merge, notes copy lost -> restore ---
# After a squash, main never had the notes file. The resume must restore
# it from the PR head. The test also removes the PR head commit from the
# local object store, so the script must fetch refs/pull/42/head.
setup_case caseM8
touch "$STATE/linear_classic" "$STATE/fail_release"
run_release "$VERSION" "$PR" "$MS" >/dev/null 2>&1
STATUSM8A=$?
rm -f "$STATE/fail_release" "${WORK:?}/${KEEP_REL:?}"
PR_HEADM8="$(cat "$STATE/pr_head" 2>/dev/null)"
(
    cd "$WORK" || exit 1
    git branch -q -D "milestone/${VERSION}" 2>/dev/null
    git update-ref -d "refs/remotes/origin/milestone/${VERSION}" 2>/dev/null
    git reflog expire --expire=now --all
    git gc -q --prune=now
)
HEAD_LOCALM8=1
git -C "$WORK" cat-file -e "${PR_HEADM8}^{commit}" 2>/dev/null || HEAD_LOCALM8=0
OUTM8="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM8=$?
WHYM8="$(check_released)"
if [ "$STATUSM8A" -eq 2 ] && [ -n "$PR_HEADM8" ] && [ "$HEAD_LOCALM8" -eq 0 ] \
    && [ "$STATUSM8" -eq 0 ] && [ -z "$WHYM8" ] \
    && [[ "$OUTM8" == *"Restored release notes from"* ]]; then
    pass "Case M8: linear, resume after the merge with no notes copy -> notes restored from the PR head"
else
    fail "Case M8: linear, restore from the PR head" "exits: $STATUSM8A $STATUSM8 (want 2 0)" \
        "PR head: [$PR_HEADM8], local before resume: $HEAD_LOCALM8 (want 0)" "check: $WHYM8" \
        "output: [$OUTM8]"
fi

# --- Case F1a: PR head ref gone on origin -> exit 2 with Restore message ---
# Same start as Case M8. Before the resume, the test deletes
# refs/pull/42/head on origin, so the fetch of the PR head fails.
setup_case caseF1a
touch "$STATE/linear_classic" "$STATE/fail_release"
run_release "$VERSION" "$PR" "$MS" >/dev/null 2>&1
STATUSF1AA=$?
rm -f "$STATE/fail_release" "${WORK:?}/${KEEP_REL:?}"
PR_HEADF1A="$(cat "$STATE/pr_head" 2>/dev/null)"
(
    cd "$WORK" || exit 1
    git branch -q -D "milestone/${VERSION}" 2>/dev/null
    git update-ref -d "refs/remotes/origin/milestone/${VERSION}" 2>/dev/null
    git reflog expire --expire=now --all
    git gc -q --prune=now
)
git -C "$ORIGIN" update-ref -d "refs/pull/${PR}/head"
HEAD_LOCALF1A=1
git -C "$WORK" cat-file -e "${PR_HEADF1A}^{commit}" 2>/dev/null || HEAD_LOCALF1A=0
OUTF1A="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSF1A=$?
LEFTF1A="$(find "$WORK/docs/plans/releases" -name "${VERSION}-release-notes.md*" 2>/dev/null)"
if [ "$STATUSF1AA" -eq 2 ] && [ -n "$PR_HEADF1A" ] && [ "$HEAD_LOCALF1A" -eq 0 ] \
    && [ "$STATUSF1A" -eq 2 ] && [[ "$OUTF1A" == *"Restore"* ]] \
    && [ "$(grep -c '^release create' "$STATE/calls")" -eq 1 ] && [ -z "$LEFTF1A" ]; then
    pass "Case F1a: PR head ref missing on origin -> exit 2 with the Restore message, no release, no notes copy"
else
    fail "Case F1a: PR head fetch fails" "exits: $STATUSF1AA $STATUSF1A (want 2 2)" \
        "PR head: [$PR_HEADF1A], local before resume: $HEAD_LOCALF1A (want 0)" \
        "release creates: $(grep -c '^release create' "$STATE/calls") (want 1)" "left behind: [$LEFTF1A]" \
        "output: [$OUTF1A]"
fi

# --- Case F1b: PR head ref points at another commit -> exit 2 -------------
# The fetch works, but the PR head commit is still absent after it.
setup_case caseF1b
touch "$STATE/linear_classic" "$STATE/fail_release"
run_release "$VERSION" "$PR" "$MS" >/dev/null 2>&1
STATUSF1BA=$?
rm -f "$STATE/fail_release" "${WORK:?}/${KEEP_REL:?}"
PR_HEADF1B="$(cat "$STATE/pr_head" 2>/dev/null)"
(
    cd "$WORK" || exit 1
    git branch -q -D "milestone/${VERSION}" 2>/dev/null
    git update-ref -d "refs/remotes/origin/milestone/${VERSION}" 2>/dev/null
    git reflog expire --expire=now --all
    git gc -q --prune=now
)
git -C "$ORIGIN" update-ref "refs/pull/${PR}/head" "$(git -C "$ORIGIN" rev-parse refs/heads/main)"
HEAD_LOCALF1B=1
git -C "$WORK" cat-file -e "${PR_HEADF1B}^{commit}" 2>/dev/null || HEAD_LOCALF1B=0
OUTF1B="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSF1B=$?
LEFTF1B="$(find "$WORK/docs/plans/releases" -name "${VERSION}-release-notes.md*" 2>/dev/null)"
if [ "$STATUSF1BA" -eq 2 ] && [ -n "$PR_HEADF1B" ] && [ "$HEAD_LOCALF1B" -eq 0 ] \
    && [ "$STATUSF1B" -eq 2 ] && [[ "$OUTF1B" == *"Restore"* ]] \
    && [ "$(grep -c '^release create' "$STATE/calls")" -eq 1 ] && [ -z "$LEFTF1B" ]; then
    pass "Case F1b: PR head ref on another commit -> exit 2 with the Restore message, no release, no notes copy"
else
    fail "Case F1b: PR head still absent after the fetch" "exits: $STATUSF1BA $STATUSF1B (want 2 2)" \
        "PR head: [$PR_HEADF1B], local before resume: $HEAD_LOCALF1B (want 0)" \
        "release creates: $(grep -c '^release create' "$STATE/calls") (want 1)" "left behind: [$LEFTF1B]" \
        "output: [$OUTF1B]"
fi

# --- Case M9: linear, gh cannot delete the local branch -> Step 10 -D -----
# gh squash-merges and then fails to delete the local branch, so the first
# run stops at Step 8 with exit 2. The rerun skips the merge. Step 10 must
# delete the squash-merged branch, which git branch -d refuses.
setup_case caseM9
touch "$STATE/linear_classic" "$STATE/local_delete_fail"
run_release "$VERSION" "$PR" "$MS" >/dev/null 2>&1
STATUSM9A=$?
BRANCH_LEFTM9A=0
git -C "$WORK" rev-parse -q --verify "refs/heads/milestone/${VERSION}" >/dev/null && BRANCH_LEFTM9A=1
rm -f "$STATE/local_delete_fail"
OUTM9="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM9=$?
WHYM9="$(check_released)"
BRANCH_LEFTM9=0
git -C "$WORK" rev-parse -q --verify "refs/heads/milestone/${VERSION}" >/dev/null && BRANCH_LEFTM9=1
if [ "$STATUSM9A" -eq 2 ] && [ "$BRANCH_LEFTM9A" -eq 1 ] && [ "$STATUSM9" -eq 0 ] && [ -z "$WHYM9" ] \
    && [ "$BRANCH_LEFTM9" -eq 0 ] && [[ "$OUTM9" == *"Deleted branch milestone/${VERSION}"* ]]; then
    pass "Case M9: linear, gh local delete fails -> rerun Step 10 deletes the squash-merged branch"
else
    fail "Case M9: linear, Step 10 deletes the local branch on the rerun" \
        "exits: $STATUSM9A $STATUSM9 (want 2 0)" "check: $WHYM9" \
        "local branch after run 1: $BRANCH_LEFTM9A (want 1), after run 2: $BRANCH_LEFTM9 (want 0)" \
        "output: [$OUTM9]"
fi

# --- Case M10: Free plan answers both reads with 403 Upgrade -> --merge ----
# A private repo on the GitHub Free plan has no protection and no rulesets.
# Such a repo cannot require linear history, so the release must go on.
setup_case caseM10
touch "$STATE/protection_upgrade"
OUTM10="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM10=$?
WHYM10="$(check_released)"
if [ "$STATUSM10" -eq 0 ] && [ -z "$WHYM10" ] && grep -q "^pr merge $PR --merge " "$STATE/calls" \
    && [[ "$OUTM10" == *"Merge method: merge"* ]] \
    && [[ "$OUTM10" != *"a command failed"* ]]; then
    pass "Case M10: 403 Upgrade to GitHub Pro on both reads -> exit 0, --merge"
else
    fail "Case M10: 403 Upgrade on both reads -> --merge" "exit: $STATUSM10 (want 0)" "check: $WHYM10" \
        "merge calls: [$(grep '^pr merge' "$STATE/calls")]" "output: [$OUTM10]"
fi

# --- Case M11: rules read fails (generic 403) -> exit 1, nothing changes ---
# Only the Upgrade text is safe to read as "not linear". Any other rules
# error must stop the run before it changes anything.
setup_case caseM11
touch "$STATE/not_protected" "$STATE/rules_fail"
BEFOREM11="$(git -C "$ORIGIN" for-each-ref)"
OUTM11="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM11=$?
AFTERM11="$(git -C "$ORIGIN" for-each-ref)"
if [ "$STATUSM11" -eq 1 ] && [ "$BEFOREM11" = "$AFTERM11" ] \
    && [[ "$OUTM11" == *"cannot read the branch protection or rules of main"* ]] \
    && [[ "$OUTM11" == *"(HTTP 403)"* ]] \
    && [[ "$OUTM11" != *"a command failed"* ]] \
    && ! grep -q '^pr merge' "$STATE/calls"; then
    pass "Case M11: rules read fails -> exit 1, origin refs unchanged, no merge"
else
    fail "Case M11: rules read fails -> exit 1" "exit: $STATUSM11 (want 1)" "output: [$OUTM11]"
fi

# --- Case M12: no classic protection, a ruleset requires linear -> --squash --
# The 404 on the classic read must not skip the rules read.
setup_case caseM12
touch "$STATE/not_protected" "$STATE/linear_ruleset"
OUTM12="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM12=$?
WHYM12="$(check_released)"
if [ "$STATUSM12" -eq 0 ] && [ -z "$WHYM12" ] && grep -q "^pr merge $PR --squash " "$STATE/calls"; then
    pass "Case M12: not protected plus a linear ruleset -> exit 0, --squash"
else
    fail "Case M12: not protected plus a linear ruleset -> --squash" "exit: $STATUSM12 (want 0)" \
        "check: $WHYM12" "merge calls: [$(grep '^pr merge' "$STATE/calls")]" "output: [$OUTM12]"
fi

# --- Case F15a: the rules count has two digits -> --squash --------------
# A count of 12 is a valid answer. A check for one digit would stop the run.
setup_case caseF15a
touch "$STATE/not_protected" "$STATE/rules_count_12"
OUTF15A="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSF15A=$?
WHYF15A="$(check_released)"
if [ "$STATUSF15A" -eq 0 ] && [ -z "$WHYF15A" ] && grep -q "^pr merge $PR --squash " "$STATE/calls"; then
    pass "Case F15a: 12 linear-history rules -> exit 0, --squash"
else
    fail "Case F15a: 12 linear-history rules -> --squash" "exit: $STATUSF15A (want 0)" "check: $WHYF15A" \
        "merge calls: [$(grep '^pr merge' "$STATE/calls")]" "output: [$OUTF15A]"
fi

# --- Case F15b: the rules read succeeds with a non-number -> exit 1 --------
# Exit 0 with text that is not a count is not a valid answer. The script
# must stop before it changes anything, not pick --squash.
setup_case caseF15b
touch "$STATE/not_protected" "$STATE/rules_garbage"
BEFOREF15B="$(git -C "$ORIGIN" for-each-ref)"
OUTF15B="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSF15B=$?
AFTERF15B="$(git -C "$ORIGIN" for-each-ref)"
if [ "$STATUSF15B" -eq 1 ] && [ "$BEFOREF15B" = "$AFTERF15B" ] \
    && [[ "$OUTF15B" == *"cannot read the branch protection or rules of main"* ]] \
    && ! grep -q '^pr merge' "$STATE/calls"; then
    pass "Case F15b: rules read gives a non-number with exit 0 -> exit 1, origin refs unchanged, no merge"
else
    fail "Case F15b: rules read gives a non-number" "exit: $STATUSF15B (want 1)" "output: [$OUTF15B]"
fi

# --- Case F15c: the rules read succeeds with no output -> exit 1 ----------
# An empty answer is not a count either. It must not pass as --squash.
setup_case caseF15c
touch "$STATE/not_protected" "$STATE/rules_empty"
BEFOREF15C="$(git -C "$ORIGIN" for-each-ref)"
OUTF15C="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSF15C=$?
AFTERF15C="$(git -C "$ORIGIN" for-each-ref)"
if [ "$STATUSF15C" -eq 1 ] && [ "$BEFOREF15C" = "$AFTERF15C" ] \
    && [[ "$OUTF15C" == *"cannot read the branch protection or rules of main"* ]] \
    && ! grep -q '^pr merge' "$STATE/calls"; then
    pass "Case F15c: rules read gives no output with exit 0 -> exit 1, origin refs unchanged, no merge"
else
    fail "Case F15c: rules read gives no output" "exit: $STATUSF15C (want 1)" "output: [$OUTF15C]"
fi

# --- Case F14a: gh warning on stderr, linear off -> --merge ---------------
# A warning line on stderr must not change the answer of either read.
setup_case caseF14a
touch "$STATE/gh_warning"
OUTF14A="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSF14A=$?
WHYF14A="$(check_released)"
if [ "$STATUSF14A" -eq 0 ] && [ -z "$WHYF14A" ] && grep -q "^pr merge $PR --merge " "$STATE/calls"; then
    pass "Case F14a: gh warning on both reads, no linear history -> exit 0, --merge"
else
    fail "Case F14a: gh warning, no linear history -> --merge" "exit: $STATUSF14A (want 0)" "check: $WHYF14A" \
        "merge calls: [$(grep '^pr merge' "$STATE/calls")]" "output: [$OUTF14A]"
fi

# --- Case F14b: gh warning on stderr, classic linear -> --squash ----------
setup_case caseF14b
touch "$STATE/gh_warning" "$STATE/linear_classic"
OUTF14B="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSF14B=$?
WHYF14B="$(check_released)"
if [ "$STATUSF14B" -eq 0 ] && [ -z "$WHYF14B" ] && grep -q "^pr merge $PR --squash " "$STATE/calls"; then
    pass "Case F14b: gh warning, classic linear history -> exit 0, --squash"
else
    fail "Case F14b: gh warning, classic linear history -> --squash" "exit: $STATUSF14B (want 0)" \
        "check: $WHYF14B" "merge calls: [$(grep '^pr merge' "$STATE/calls")]" "output: [$OUTF14B]"
fi

# --- Case M13: local branch has a new commit -> kept on the rerun ----------
# The first run fails at Step 13, after gh deleted the local branch.
# The test then makes a local branch with one extra commit. The rerun must
# keep it, because the commit is not in the PR.
setup_case caseM13
touch "$STATE/fail_release"
run_release "$VERSION" "$PR" "$MS" >/dev/null 2>&1
STATUSM13A=$?
(
    cd "$WORK" || exit 1
    git checkout -q -b "milestone/${VERSION}" "$(cat "$STATE/pr_head")"
    echo extra > extra.txt
    git add extra.txt
    git commit -q -m "local work not in the PR"
    git checkout -q main
) || exit 1
EXTRA_TIP="$(git -C "$WORK" rev-parse "refs/heads/milestone/${VERSION}")"
rm -f "$STATE/fail_release"
OUTM13="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM13=$?
TIP_AFTER="$(git -C "$WORK" rev-parse -q --verify "refs/heads/milestone/${VERSION}")"
if [ "$STATUSM13A" -eq 2 ] && [ "$STATUSM13" -eq 0 ] \
    && [[ "$OUTM13" == *"Kept local milestone/${VERSION}"* ]] \
    && [ "$TIP_AFTER" = "$EXTRA_TIP" ]; then
    pass "Case M13: local branch with an extra commit -> exit 0, kept, tip unchanged"
else
    fail "Case M13: local branch with an extra commit is kept" "exits: $STATUSM13A $STATUSM13 (want 2 0)" \
        "tip before: [$EXTRA_TIP], after: [$TIP_AFTER]" "output: [$OUTM13]"
fi

# --- Case M14: git branch -D fails -> message, release goes on -------------
# gh leaves the local branch (as in M9), so the rerun reaches Step 10.
setup_case caseM14
touch "$STATE/local_delete_fail"
run_release "$VERSION" "$PR" "$MS" >/dev/null 2>&1
STATUSM14A=$?
rm -f "$STATE/local_delete_fail"
OUTM14="$(cd "$WORK" && PATH="$GITSTUBDIR:$STUBDIR:$PATH" FAIL_GIT_BRANCH_D=1 STUB_STATE="$STATE" \
    STUB_ORIGIN="$ORIGIN" "$SCRIPT" "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM14=$?
WHYM14="$(check_released)"
if [ "$STATUSM14A" -eq 2 ] && [ "$STATUSM14" -eq 0 ] && [ -z "$WHYM14" ] \
    && [[ "$OUTM14" == *"Could not delete local milestone/${VERSION}"* ]]; then
    pass "Case M14: branch delete fails -> exit 0, message printed, tag and release done"
else
    fail "Case M14: branch delete fails" "exit: $STATUSM14 (want 0)" "check: $WHYM14" "output: [$OUTM14]"
fi

# --- Case M15: rerun after the merge does not read branch protection -------
# The PR is MERGED on the rerun. A 403 on the protection read must not matter.
setup_case caseM15
touch "$STATE/fail_release"
run_release "$VERSION" "$PR" "$MS" >/dev/null 2>&1
STATUSM15A=$?
rm -f "$STATE/fail_release" "$WORK/$KEEP_REL"
touch "$STATE/protection_403"
CALLS_BEFOREM15="$(wc -l < "$STATE/calls")"
OUTM15="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSM15=$?
WHYM15="$(check_released)"
if [ "$STATUSM15A" -eq 2 ] && [ "$STATUSM15" -eq 0 ] && [ -z "$WHYM15" ] \
    && [[ "$OUTM15" != *"cannot read the branch protection"* ]] \
    && ! tail -n +"$((CALLS_BEFOREM15 + 1))" "$STATE/calls" | grep -q 'branches/main/protection'; then
    pass "Case M15: rerun after the merge -> exit 0, no protection read"
else
    fail "Case M15: rerun after the merge reads no protection" "exits: $STATUSM15A $STATUSM15 (want 2 0)" "check: $WHYM15" "output: [$OUTM15]"
fi

# --- Release key: publish (default) or draft ----------------------------

# --- Case K1: no release key -> --latest -------------------------------
setup_case caseK1
OUTK1="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSK1=$?
WHYK1="$(check_released --latest)"
if [ "$STATUSK1" -eq 0 ] && [ -z "$WHYK1" ] && ! grep -q '^release create .*--draft' "$STATE/calls" \
    && [ "$(printf '%s\n' "$OUTK1" | tail -n 1)" = "Release ${VERSION} is published and marked Latest (no release key)." ]; then
    pass "Case K1: no release key -> --latest, last line says published (no release key)"
else
    fail "Case K1: no release key -> --latest" "exit: $STATUSK1 (want 0)" "check: $WHYK1" "output: [$OUTK1]"
fi

# --- Case K2: release: publish -> --latest -----------------------------
setup_case caseK2 'release: `publish`'
OUTK2="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSK2=$?
WHYK2="$(check_released --latest)"
if [ "$STATUSK2" -eq 0 ] && [ -z "$WHYK2" ] \
    && [ "$(printf '%s\n' "$OUTK2" | tail -n 1)" = "Release ${VERSION} is published and marked Latest (release: publish)." ]; then
    pass "Case K2: release: publish -> --latest, last line names release: publish"
else
    fail "Case K2: release: publish -> --latest" "exit: $STATUSK2 (want 0)" "check: $WHYK2" "output: [$OUTK2]"
fi

# --- Case K3: release: draft -> --draft --------------------------------
setup_case caseK3 'release: `draft`'
OUTK3="$(run_release "$VERSION" "$PR" "$MS" 2>&1)"
STATUSK3=$?
WHYK3="$(check_released --draft)"
if [ "$STATUSK3" -eq 0 ] && [ -z "$WHYK3" ] && ! grep -q '^release create .*--latest' "$STATE/calls" \
    && [ "$(printf '%s\n' "$OUTK3" | tail -n 1)" = "Release ${VERSION} is a DRAFT (release: draft). Publish it when you deploy." ]; then
    pass "Case K3: release: draft -> --draft, last line says DRAFT (release: draft)"
else
    fail "Case K3: release: draft -> --draft" "exit: $STATUSK3 (want 0)" "check: $WHYK3" "output: [$OUTK3]"
fi

# --- Case K4: release: later -> exit 2, nothing changes ----------------
setup_case caseK4 'release: `later`'
BEFOREK4="$(git -C "$ORIGIN" for-each-ref)"
OUTK4="$(run_release "$VERSION" "$PR" "$MS" 2>&1 >/dev/null)"
STATUSK4=$?
AFTERK4="$(git -C "$ORIGIN" for-each-ref)"
if [ "$STATUSK4" -eq 2 ] && [ "$BEFOREK4" = "$AFTERK4" ] \
    && [ "$OUTK4" = "flow-release-milestone: release key is 'later'. Allowed values: publish, draft." ] \
    && ! grep -qE '^(pr merge|release create)' "$STATE/calls"; then
    pass "Case K4: release: later -> exit 2 with the allowed values, no push, no merge, no tag"
else
    fail "Case K4: release: later -> exit 2" "exit: $STATUSK4 (want 2)" "stderr: [$OUTK4]"
fi

harness_report
