#!/bin/bash
#
# Tests the self-referential guard of claude-review.yml (issues #31 and #32).
# The review action refuses to run when a workflow file at the PR head differs
# from the copy on the default branch. Then the action writes no execution
# file, and the run has no review. The cause can be a real failure, a branch
# that changed the workflow on purpose, or a base branch with an old copy.
# Each cause needs a different message and a different Gate result.
#
# The step "Check workflow match" finds the cause. It compares blobs at the
# default branch, the head, and the merge base. A lookup that fails counts as
# no answer, so the guard fails closed. The steps "Post review" and "Gate"
# read its result and give the matching message. The test checks three things
# for each of the 3 review jobs:
#   - structure: the steps are in the right order, and the Gate calls no gh
#   - match: the step gives edited, stale, or none for each blob case
#   - post and gate: each result gives the right comment and exit code. Post
#     review also posts nothing when the Claude step did not run.
#
# The test runs the run: block of each step with a fake gh. It cannot check
# how GitHub Actions runs the workflow.
#
# WORKFLOW_DIR points the test at a copy of .github/workflows.
#
# Usage: bash tests/workflows/test-review-gate-guard.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/gh-stub.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW_DIR="${WORKFLOW_DIR:-$REAL_REPO/.github/workflows}"
REVIEW="$WORKFLOW_DIR/claude-review.yml"

TMPROOT="$(mktemp -d)"
BIN="$TMPROOT/bin"
gh_stub_install "$BIN"
mkdir -p "$TMPROOT/home" "$TMPROOT/scripts"
printf '[]\n' > "$TMPROOT/execution.json"

JOBS="pr-to-milestone-review milestone-review comment-deep-review"
MATCH_NAME="Check workflow match"
HEAD40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# Blob fixtures. The workflow keeps only a value that looks like a SHA.
BLOB_M="cccccccccccccccccccccccccccccccccccccccc"
BLOB_H="dddddddddddddddddddddddddddddddddddddddd"
BASE40="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
CALLER=".github/workflows/claude-code-review.yml"
SELF=".github/workflows/claude-review.yml"
WFREF="o/r/$CALLER@refs/heads/x"
URL="https://example.test/o/r/actions/runs/42"

if [ ! -f "$REVIEW" ]; then
    fail "claude-review.yml exists" "missing: $REVIEW"
    harness_report
fi

# step_line <name> <n>: prints the line of the n-th step with this name.
step_line() {
    awk -v want="      - name: $1" -v n="$2" '
        $0 == want { c++; if (c == n) { print NR; exit } }
    ' "$REVIEW"
}

# step_count <name>: prints how many steps have this name.
step_count() {
    awk -v want="      - name: $1" '$0 == want { c++ } END { print c + 0 }' "$REVIEW"
}

# job_of <line>: prints the name of the job that holds the line.
job_of() {
    awk -v l="$1" '
        NR > l { exit }
        /^  [a-z][a-z0-9-]*:$/ { j = $0; sub(/^ +/, "", j); sub(/:$/, "", j) }
        END { print j }
    ' "$REVIEW"
}

# step_text <line>: prints the step that starts at the line, up to the next
# step or job.
step_text() {
    awk -v s="$1" '
        NR == s { on = 1; print; next }
        on && (/^      - / || /^  [a-z]/) { exit }
        on { print }
    ' "$REVIEW"
}

# step_run <line>: prints the run: block of the step, with its indent removed.
# The block ends at the first non-blank line with less indent, such as the
# comment line above the next step.
step_run() {
    awk -v s="$1" '
        NR <= s { next }
        done { next }
        /^      - / || /^  [a-z]/ { done = 1; next }
        on && !/^ *$/ && !/^          / { done = 1; next }
        on { sub(/^          /, ""); print }
        /^        run: \|$/ { on = 1 }
    ' "$REVIEW"
}

# step_script <name> <n>: writes the run: block to a file and prints its path.
step_script() {
    local line f
    line="$(step_line "$1" "$2")"
    f="$TMPROOT/scripts/$(printf '%s' "$1" | tr -c 'A-Za-z0-9\n' '_')-$2.sh"
    [ -n "$line" ] && step_run "$line" > "$f"
    printf '%s' "$f"
}

# Each step must exist 3 times, or the cases below check nothing.
# Each group has its own flag, so a missing match step does not hide a wrong
# Post review or Gate.
steps_ok=1
match_ok=1
post_ok=1
gate_ok=1
for name in "$MATCH_NAME" "Post review" "Gate"; do
    count="$(step_count "$name")"
    if [ "$count" = 3 ]; then
        pass "claude-review.yml has 3 '$name' steps"
    else
        fail "claude-review.yml has 3 '$name' steps" "found $count"
        steps_ok=0
        case "$name" in
            "$MATCH_NAME") match_ok=0 ;;
            "Post review") post_ok=0 ;;
            Gate) gate_ok=0 ;;
        esac
    fi
done

# ---------------------------------------------------------------- structure
if [ "$steps_ok" = 1 ]; then
    n=0
    first_run=""
    for job in $JOBS; do
        n=$((n + 1))
        m="$(step_line "$MATCH_NAME" "$n")"
        p="$(step_line "Post review" "$n")"
        g="$(step_line "Gate" "$n")"
        mtext="$(step_text "$m")"
        ptext="$(step_text "$p")"
        gtext="$(step_text "$g")"

        if [ "$(job_of "$m")" = "$job" ] && [ "$(job_of "$p")" = "$job" ] \
            && [ "$(job_of "$g")" = "$job" ]; then
            pass "$job: match, Post review, and Gate are in this job"
        else
            fail "$job: match, Post review, and Gate are in this job" \
                "jobs: $(job_of "$m") $(job_of "$p") $(job_of "$g")"
        fi

        # The match step needs the outcome of the Claude step, so it must
        # come after it. Post review and the Gate need the match output.
        c="$(awk -v j="$job" -v m="$m" '
            /^  [a-z][a-z0-9-]*:$/ { cur = $0; sub(/^ +/, "", cur); sub(/:$/, "", cur) }
            cur == j && /^        id: claude-review$/ { print NR; exit }
        ' "$REVIEW")"
        if [ -n "$c" ] && [ "$c" -lt "$m" ] && [ "$m" -lt "$p" ] && [ "$p" -lt "$g" ]; then
            pass "$job: order is Claude step, match, Post review, Gate"
        else
            fail "$job: order is Claude step, match, Post review, Gate" \
                "lines: claude=${c:-none} match=$m post=$p gate=$g"
        fi

        if printf '%s\n' "$mtext" | grep -qx '        id: match' \
            && printf '%s\n' "$mtext" | grep -qx '        if: always()'; then
            pass "$job: match step has id: match and if: always()"
        else
            fail "$job: match step has id: match and if: always()"
        fi

        if printf '%s\n' "$mtext" | grep -q 'continue-on-error'; then
            fail "$job: match step has no continue-on-error"
        else
            pass "$job: match step has no continue-on-error"
        fi

        # shellcheck disable=SC2016 # the text is literal workflow text
        want_env='          MATCH_RESULT: ${{ steps.match.outputs.result }}'
        if printf '%s\n' "$ptext" | grep -qxF "$want_env"; then
            pass "$job: Post review reads MATCH_RESULT from the match step"
        else
            fail "$job: Post review reads MATCH_RESULT from the match step"
        fi
        if printf '%s\n' "$gtext" | grep -qxF "$want_env"; then
            pass "$job: Gate reads MATCH_RESULT from the match step"
        else
            fail "$job: Gate reads MATCH_RESULT from the match step"
        fi

        env_ok=1
        env_bad=""
        for want in \
            "ptext|          MATCH_PATH: \${{ steps.match.outputs.path }}" \
            "ptext|          CLAUDE_OUTCOME: \${{ steps.claude-review.outcome }}" \
            "gtext|          MATCH_PATH: \${{ steps.match.outputs.path }}"; do
            which="${want%%|*}"
            line="${want#*|}"
            if [ "$which" = ptext ]; then t="$ptext"; else t="$gtext"; fi
            printf '%s\n' "$t" | grep -qxF -- "$line" || { env_ok=0; env_bad="$env_bad [$which $line]"; }
        done
        for want in "gtext|RUN_URL" "mtext|EXECUTION_FILE" "mtext|WF_REF" \
            "mtext|DEFAULT_BRANCH" "mtext|HEAD_SHA"; do
            which="${want%%|*}"
            key="${want#*|}"
            case "$which" in
                gtext) t="$gtext" ;;
                *) t="$mtext" ;;
            esac
            printf '%s\n' "$t" | grep -q "^          $key: " || { env_ok=0; env_bad="$env_bad [$which $key]"; }
        done
        if [ "$env_ok" = 1 ]; then
            pass "$job: Post review, Gate, and match steps have the env keys they read"
        else
            fail "$job: Post review, Gate, and match steps have the env keys they read" "missing:$env_bad"
        fi

        # The Gate reads outputs only. A gh call in it could fail for a
        # reason that has nothing to do with the review.
        grep_gh="$(step_run "$g" | grep -v '^ *#' | grep -E '(^|[^A-Za-z0-9_./-])gh[[:space:]]' || true)"
        if [ -z "$grep_gh" ] && [ -n "$(step_run "$g")" ]; then
            pass "$job: Gate run: block has no gh call"
        else
            fail "$job: Gate run: block has no gh call" "found: $grep_gh"
        fi

        this_run="$(step_run "$m")"
        if [ -z "$this_run" ]; then
            fail "$job: match step has a run: block"
        elif [ -z "$first_run" ]; then
            first_run="$this_run"
            pass "$job: match step has a run: block"
        elif [ "$this_run" = "$first_run" ]; then
            pass "$job: match run: block equals the first job's block"
        else
            fail "$job: match run: block equals the first job's block"
        fi
    done
fi

# -------------------------------------------------------------------- match
# The per-path fake. The shared stub gives one answer for every path. This
# script answers for one path only and passes the other calls (exit 3) to
# the stub. It takes its blobs from XMAIN, XHEAD, and XBASE.
cat > "$TMPROOT/extra.sh" << 'EOF'
#!/bin/bash
case "$2" in
    repos/*/contents/*\?ref=*) ;;
    *) exit 3 ;;
esac
path="${2#*/contents/}"
path="${path%%\?*}"
ref="${2##*\?ref=}"
[ "$path" = "${XPATH:-}" ] || exit 3
if [ "$ref" = main ]; then
    blob="${XMAIN:-}"
elif [ "$ref" = "${STUB_MERGE_BASE_SHA:-}" ]; then
    blob="${XBASE:-}"
else
    blob="${XHEAD:-}"
fi
[ -n "$blob" ] || exit 1
printf '%s\n' "$blob"
EOF
chmod +x "$TMPROOT/extra.sh"

# run_match <script> [VAR=value ...]
# Runs the match step in a clean environment. A later VAR replaces the
# default. It sets MOUT (output), MRC (exit code), MRESULT, MPATH, and MLOG
# (the gh calls).
run_match() {
    local script="$1"
    shift
    rm -f "$TMPROOT/gh.log" "$TMPROOT/gho"
    : > "$TMPROOT/gho"
    MOUT="$(cd "$TMPROOT" && env -i PATH="$BIN:$PATH" HOME="$TMPROOT/home" \
        GH_TOKEN=x REPO=o/r HEAD_SHA="$HEAD40" EXECUTION_FILE= WF_REF="$WFREF" \
        DEFAULT_BRANCH=main GITHUB_OUTPUT="$TMPROOT/gho" STUB_LOG="$TMPROOT/gh.log" \
        STUB_MERGE_BASE_SHA="$BASE40" "$@" bash "$script" 2>&1)"
    MRC=$?
    MRESULT="$(grep '^result=' "$TMPROOT/gho" | tail -1 | cut -d= -f2-)"
    MPATH="$(grep '^path=' "$TMPROOT/gho" | tail -1 | cut -d= -f2-)"
    MLOG="$(cat "$TMPROOT/gh.log" 2>/dev/null || true)"
    MRCOUNT="$(grep -c '^result=' "$TMPROOT/gho" || true)"
}

# out_has <label> <text>: passes when the last match run printed the text.
out_has() {
    case "$MOUT" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "output lacks [$2]: $MOUT" ;;
    esac
}

# expect_match <label> <result> <path> <script> [VAR=value ...]
expect_match() {
    local label="$1" want="$2" wpath="$3" script="$4"
    shift 4
    run_match "$script" "$@"
    if [ "$MRC" != 0 ]; then
        fail "$label" "exit $MRC: $MOUT"
    elif [ "$MRCOUNT" != 1 ]; then
        fail "$label" "GITHUB_OUTPUT has $MRCOUNT result= lines, not 1"
    elif [ "$MRESULT" != "$want" ] || [ "$MPATH" != "$wpath" ]; then
        fail "$label" "want result=$want path=$wpath, got result=$MRESULT path=$MPATH"
    else
        pass "$label"
    fi
}

if [ "$match_ok" = 1 ]; then
    n=0
    for job in $JOBS; do
        n=$((n + 1))
        s="$(step_script "$MATCH_NAME" "$n")"
        l="match ($job)"

        expect_match "$l: branch edited the caller file gives edited" \
            edited "$CALLER" "$s" STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB="$BLOB_H" STUB_BASE_BLOB="$BLOB_M"

        expect_match "$l: base branch has an old copy gives stale" \
            stale "$CALLER" "$s" STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB="$BLOB_H" STUB_BASE_BLOB="$BLOB_H"

        expect_match "$l: equal blobs give none" \
            none "" "$s" STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB="$BLOB_M" STUB_BASE_BLOB="$BLOB_M"

        expect_match "$l: an execution file gives none" \
            none "" "$s" EXECUTION_FILE=/x/execution.json \
            STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB="$BLOB_H" STUB_BASE_BLOB="$BLOB_M"
        if [ -z "$MLOG" ]; then
            pass "$l: an execution file makes no gh call"
        else
            fail "$l: an execution file makes no gh call" "calls: $MLOG"
        fi

        expect_match "$l: a failed compare call gives none" \
            none "" "$s" STUB_MERGE_BASE_SHA= \
            STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB="$BLOB_H" STUB_BASE_BLOB="$BLOB_M"
        out_has "$l: a failed compare call prints the merge base warning" \
            "Could not get the merge base"

        expect_match "$l: a merge base that is not a SHA gives none" \
            none "" "$s" STUB_MERGE_BASE_SHA=null \
            STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB="$BLOB_H" STUB_BASE_BLOB="$BLOB_M"
        out_has "$l: a merge base that is not a SHA prints the merge base warning" \
            "Could not get the merge base"

        # Real gh prints an error body on stdout when a lookup fails. The stub
        # does the same, so a failed lookup is not an empty string.
        expect_match "$l: failed main and merge base lookups give none" \
            none "" "$s" STUB_MERGE_BASE_SHA= \
            STUB_MAIN_BLOB= STUB_HEAD_BLOB="$BLOB_H" STUB_BASE_BLOB=
        expect_match "$l: a failed main lookup gives none" \
            none "" "$s" \
            STUB_MAIN_BLOB= STUB_HEAD_BLOB="$BLOB_H" STUB_BASE_BLOB="$BLOB_M"
        expect_match "$l: a blob that is not a SHA gives none" \
            none "" "$s" STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB=null STUB_BASE_BLOB="$BLOB_M"

        expect_match "$l: no blob at the head gives none" \
            none "" "$s" STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB= STUB_BASE_BLOB="$BLOB_M"

        expect_match "$l: no blob at the merge base gives none" \
            none "" "$s" STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB="$BLOB_H" STUB_BASE_BLOB=

        expect_match "$l: a bad WF_REF gives none" \
            none "" "$s" WF_REF=o/r/foo@x \
            STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB="$BLOB_H" STUB_BASE_BLOB="$BLOB_M"
        out_has "$l: a bad WF_REF prints a ::warning::" "::warning::Could not parse a workflow path"
        if [ -z "$MLOG" ]; then
            pass "$l: a bad WF_REF makes no gh call"
        else
            fail "$l: a bad WF_REF makes no gh call" "calls: $MLOG"
        fi

        # Only claude-review.yml differs. The caller file is the same on
        # both refs.
        expect_match "$l: only claude-review.yml edited gives edited for it" \
            edited "$SELF" "$s" STUB_EXTRA="$TMPROOT/extra.sh" XPATH="$SELF" \
            XMAIN="$BLOB_M" XHEAD="$BLOB_H" XBASE="$BLOB_M" \
            STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB="$BLOB_M" STUB_BASE_BLOB="$BLOB_M"

        # The caller path comes first, and stale ends the loop.
        expect_match "$l: stale caller and edited claude-review.yml give stale for the caller" \
            stale "$CALLER" "$s" STUB_EXTRA="$TMPROOT/extra.sh" XPATH="$SELF" \
            XMAIN="$BLOB_M" XHEAD="$BLOB_H" XBASE="$BLOB_M" \
            STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB="$BLOB_H" STUB_BASE_BLOB="$BLOB_H"

        # The edited caller must not hide a stale claude-review.yml.
        expect_match "$l: edited caller and stale claude-review.yml give stale for claude-review.yml" \
            stale "$SELF" "$s" STUB_EXTRA="$TMPROOT/extra.sh" XPATH="$SELF" \
            XMAIN="$BLOB_M" XHEAD="$BLOB_H" XBASE="$BLOB_H" \
            STUB_MAIN_BLOB="$BLOB_M" STUB_HEAD_BLOB="$BLOB_H" STUB_BASE_BLOB="$BLOB_M"
    done
fi

# --------------------------------------------------------------- post review
# run_post <script> <posted dir> [VAR=value ...]
# Sets POUT, PRC, and PVERDICT. The run uses an empty STRUCTURED_OUTPUT and
# an empty EXECUTION_FILE unless the call replaces them. CLAUDE_OUTCOME is
# failure, which is the outcome when the action stops before Claude.
run_post() {
    local script="$1" posted="$2"
    shift 2
    rm -rf "$posted" "$TMPROOT/rt"
    mkdir -p "$TMPROOT/rt"
    : > "$TMPROOT/gho"
    POUT="$(cd "$TMPROOT" && env -i PATH="$BIN:$PATH" HOME="$TMPROOT/home" \
        GH_TOKEN=x STRUCTURED_OUTPUT= HEAD_SHA="$HEAD40" PR_NUM=7 REPO=o/r \
        RUN_URL="$URL" EXECUTION_FILE= MATCH_RESULT= MATCH_PATH= CLAUDE_OUTCOME=failure \
        RUNNER_TEMP="$TMPROOT/rt" GITHUB_OUTPUT="$TMPROOT/gho" \
        STUB_POSTED_DIR="$posted" "$@" bash "$script" 2>&1)"
    PRC=$?
    PVERDICT="$(grep '^verdict=' "$TMPROOT/gho" | tail -1 | cut -d= -f2-)"
}

# posted_count <dir>: prints the number of PR comments that the stub saved.
posted_count() {
    find "$1" -type f -name '*.md' 2> /dev/null | wc -l | tr -d ' '
}

# has <file> <text> <label>: passes when the file has the text.
has() {
    if grep -qF -- "$2" "$1"; then pass "$3"; else fail "$3" "missing: $2"; fi
}

if [ "$post_ok" = 1 ]; then
    n=0
    for job in $JOBS; do
        n=$((n + 1))
        s="$(step_script "Post review" "$n")"
        l="post ($job)"
        posted="$TMPROOT/posted"

        run_post "$s" "$posted" MATCH_RESULT=edited MATCH_PATH="$CALLER"
        if [ "$PRC" = 0 ] && [ "$(posted_count "$posted")" = 0 ] && [ "$PVERDICT" = none ]; then
            pass "$l: edited exits 0, posts no comment, and records verdict none"
        else
            fail "$l: edited exits 0, posts no comment, and records verdict none" \
                "exit $PRC, comments $(posted_count "$posted"), verdict $PVERDICT: $POUT"
        fi

        run_post "$s" "$posted" MATCH_RESULT=stale MATCH_PATH="$CALLER"
        if [ "$PRC" != 0 ] || [ "$(posted_count "$posted")" != 1 ]; then
            fail "$l: stale posts one comment and exits 0" \
                "exit $PRC, comments $(posted_count "$posted"): $POUT"
        else
            pass "$l: stale posts one comment and exits 0"
            body="$posted/1.md"
            has "$body" "$CALLER" "$l: stale comment names the path"
            has "$body" "copy the file from the default branch onto the base branch" \
                "$l: stale comment says to copy the file onto an old base branch"
            has "$body" "update this branch from its base branch" \
                "$l: stale comment says to update the branch from its base"
            has "$body" "Run log: $URL" "$l: stale comment has the run link"
            if [ "$PVERDICT" = none ]; then
                pass "$l: stale writes verdict=none"
            else
                fail "$l: stale writes verdict=none" "verdict: $PVERDICT"
            fi
            if grep -q 'claude-review-verdict' "$body"; then
                fail "$l: stale comment has no verdict line"
            else
                pass "$l: stale comment has no verdict line"
            fi
        fi

        run_post "$s" "$posted" MATCH_RESULT=none
        if [ "$PRC" != 0 ] || [ "$(posted_count "$posted")" != 1 ]; then
            fail "$l: none posts one comment and exits 0" \
                "exit $PRC, comments $(posted_count "$posted"): $POUT"
        else
            pass "$l: none posts one comment and exits 0"
            body="$posted/1.md"
            has "$body" "stopped before it started Claude" \
                "$l: none comment says the action stopped before Claude"
            has "$body" "Run log: $URL" "$l: none comment has the run link"
            if [ "$PVERDICT" = none ]; then
                pass "$l: none writes verdict=none"
            else
                fail "$l: none writes verdict=none" "verdict: $PVERDICT"
            fi
            if grep -q 'claude-review-verdict' "$body"; then
                fail "$l: none comment has no verdict line"
            else
                pass "$l: none comment has no verdict line"
            fi
        fi

        # The Claude step was skipped or cancelled (an earlier step failed,
        # or the run was cancelled). The log of the failed step has the cause.
        for outcome in skipped cancelled; do
            run_post "$s" "$posted" MATCH_RESULT=none CLAUDE_OUTCOME=$outcome
            if [ "$PRC" = 0 ] && [ "$(posted_count "$posted")" = 0 ] && [ "$PVERDICT" = none ]; then
                pass "$l: outcome $outcome posts no comment, exits 0, and writes verdict=none"
            else
                fail "$l: outcome $outcome posts no comment, exits 0, and writes verdict=none" \
                    "exit $PRC, comments $(posted_count "$posted"), verdict $PVERDICT: $POUT"
            fi
        done

        # Claude ran, so the guard does not apply. The note says that the
        # output was not valid, whatever the match result is.
        run_post "$s" "$posted" MATCH_RESULT=edited MATCH_PATH="$CALLER" \
            CLAUDE_OUTCOME=success EXECUTION_FILE="$TMPROOT/execution.json"
        if [ "$PRC" = 0 ] && [ "$(posted_count "$posted")" = 1 ] && [ "$PVERDICT" = none ] \
            && grep -qF "did not return a valid review" "$posted/1.md"; then
            pass "$l: an execution file and edited post the invalid-review note"
        else
            fail "$l: an execution file and edited post the invalid-review note" \
                "exit $PRC, comments $(posted_count "$posted"), verdict $PVERDICT: $POUT"
        fi

        # The action can exit 0 with no execution file, so success must
        # post the note too. An empty or unknown result is not edited, so
        # it must not silence the note.
        for case_ in "none success" "|failure" "bogus failure"; do
            mr="${case_%% *}"; oc="${case_##* }"
            [ "$case_" = "|failure" ] && { mr=""; oc=failure; }
            run_post "$s" "$posted" "MATCH_RESULT=$mr" "CLAUDE_OUTCOME=$oc"
            if [ "$PRC" = 0 ] && [ "$(posted_count "$posted")" = 1 ] \
                && grep -qF "stopped before it started Claude" "$posted/1.md"; then
                pass "$l: MATCH_RESULT '$mr' with outcome $oc posts the stopped-before-Claude comment"
            else
                fail "$l: MATCH_RESULT '$mr' with outcome $oc posts the stopped-before-Claude comment" \
                    "exit $PRC, comments $(posted_count "$posted"): $POUT"
            fi
        done
    done
fi

# --------------------------------------------------------------------- gate

# run_gate <script> [VAR=value ...]
# Sets GOUT and GRC. The defaults are the no-verdict case with no execution
# file.
run_gate() {
    local script="$1"
    shift
    GOUT="$(cd "$TMPROOT" && env -i PATH="$BIN:$PATH" HOME="$TMPROOT/home" \
        VERDICT=none BLOCKING= HEAD_SHA="$HEAD40" EXECUTION_FILE= \
        DEFAULT_BRANCH=main MATCH_RESULT= MATCH_PATH= RUN_URL="$URL" \
        "$@" bash "$script" 2>&1)"
    GRC=$?
}

# gate_expect <label> <exit code> <text that the output must have>...
gate_expect() {
    local label="$1" want_rc="$2" t bad=""
    shift 2
    for t in "$@"; do
        case "$GOUT" in
            *"$t"*) ;;
            *) bad="$bad [$t]" ;;
        esac
    done
    if [ "$GRC" != "$want_rc" ]; then
        fail "$label" "want exit $want_rc, got $GRC: $GOUT"
    elif [ -n "$bad" ]; then
        fail "$label" "output lacks:$bad. Output: $GOUT"
    else
        pass "$label"
    fi
}

if [ "$gate_ok" = 1 ]; then
    n=0
    for job in $JOBS; do
        n=$((n + 1))
        s="$(step_script "Gate" "$n")"
        l="gate ($job)"

        run_gate "$s" VERDICT=ok BLOCKING=0 EXECUTION_FILE="$TMPROOT/execution.json"
        gate_expect "$l: verdict ok with 0 blocking exits 0" 0

        run_gate "$s" MATCH_RESULT=edited MATCH_PATH="$CALLER"
        gate_expect "$l: no verdict and edited exits 0 with a warning" 0 \
            "::warning::" "$CALLER"
        case "$GOUT" in
            *'::error::'*) fail "$l: edited prints no ::error::" "output: $GOUT" ;;
            *) pass "$l: edited prints no ::error::" ;;
        esac

        run_gate "$s" MATCH_RESULT=stale MATCH_PATH="$CALLER"
        gate_expect "$l: no verdict and stale exits 1 and says to sync" 1 \
            "::error::" "$CALLER" "onto the base branch" \
            "update this branch from its base branch"

        run_gate "$s" MATCH_RESULT=none
        gate_expect "$l: no verdict, none, and no execution file exits 1" 1 \
            "::error::" "stopped before it started Claude" "$URL"

        run_gate "$s" MATCH_RESULT=none EXECUTION_FILE="$TMPROOT/execution.json"
        gate_expect "$l: no verdict, none, and an execution file exits 1" 1 \
            "::error::No review verdict" "Post review recorded no verdict"

        run_gate "$s"
        gate_expect "$l: an empty MATCH_RESULT with no execution file exits 1" 1 \
            "::error::" "stopped before it started Claude"

        run_gate "$s" MATCH_RESULT=bogus
        gate_expect "$l: an unknown MATCH_RESULT exits 1" 1 "::error::"

        # A verdict from Post review beats the match result.
        run_gate "$s" VERDICT=ok BLOCKING=2 MATCH_RESULT=edited MATCH_PATH="$CALLER" \
            EXECUTION_FILE="$TMPROOT/execution.json"
        gate_expect "$l: blocking findings and edited exit 1" 1 "::error::"

        run_gate "$s" VERDICT=post_failed MATCH_RESULT=edited MATCH_PATH="$CALLER"
        gate_expect "$l: a failed post and edited exit 1" 1 "::error::"
    done
fi

harness_report
