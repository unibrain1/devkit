#!/bin/bash
#
# Tests the token redaction of the review renderer in claude-review.yml
# (issue #47). Each review job renders the structured model output to
# Markdown with the jq program in RENDER_FILTER. The program must replace
# a token-like string with [redacted] in summary_markdown and in the title,
# location, and detail of each finding. It must do so also when a removed
# HTML comment marker joins the token, and for a bare prefix with no body.
#
# The test reads the 3 RENDER_FILTER values from the workflow text, checks
# that they are the same, and runs them with jq on fixture JSON. It cannot
# check what the model writes. It checks only what the renderer prints.
#
# WORKFLOW_DIR points the test at a copy of .github/workflows.
#
# Usage: bash tests/workflows/test-review-token-filter.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW_DIR="${WORKFLOW_DIR:-$REAL_REPO/.github/workflows}"
REVIEW="$WORKFLOW_DIR/claude-review.yml"

TMPROOT="$(mktemp -d)"

if ! command -v jq > /dev/null 2>&1; then
    fail "jq is installed" "jq is not installed"
    harness_report
fi
if [ ! -f "$REVIEW" ]; then
    fail "claude-review.yml exists" "missing: $REVIEW"
    harness_report
fi

# extract_filters <file> <outdir>
# Writes each RENDER_FILTER value to <outdir>/filter-N and prints the count.
# A value starts on the line after "RENDER_FILTER='" and ends at the first
# line that ends with a single quote. The jq program has no single quote,
# so the first such line is the closing one. Lines stay as they are.
extract_filters() {
    awk -v dir="$2" '
        on {
            line = $0
            if (line ~ /\x27$/) { sub(/\x27$/, "", line); on = 0 }
            print line >> out
            if (!on) close(out)
            next
        }
        /^ *RENDER_FILTER=\x27$/ { n++; on = 1; out = dir "/filter-" n; printf "" > out }
        END { print n + 0 }
    ' "$1"
}

# Token text built from parts, so a secret scanner does not flag this file.
# Each body is longer than the {20,} minimum of the redact rules.
ALNUM36="Ab3dEf6hIj9lMn2pQr5tUv8xYz1BcDeFgHiJ"
ALNUM30="Zq7Xw5Ec3Rv1Tb9Yn7Um5Ik3Ol1Pa"
B_GHS="ghs_${ALNUM36}"
B_GHP="ghp_${ALNUM36}"
B_GHO="gho_${ALNUM36}"
B_GHU="ghu_${ALNUM36}"
B_GHR="ghr_${ALNUM36}"
B_PAT="github_pat_11ABCDEFG0${ALNUM36}_${ALNUM36}"
B_ANT="sk-ant-api03-${ALNUM36}-${ALNUM36}_Zz"
ALL_TOKENS="$B_GHS $B_GHP $B_GHO $B_GHU $B_GHR $B_PAT $B_ANT"

# leaks <output>
# Returns 0 when the output still holds token text: any prefix, or any
# body piece. A body piece alone is a leak, so a filter that removes only
# the prefix does not pass.
leaks() {
    local needle
    for needle in 'ghp_' 'ghs_' 'gho_' 'ghu_' 'ghr_' 'github_pat_' 'sk-ant-' \
        "$ALNUM36" "$ALNUM30" '11ABCDEFG0' 'api03-'; do
        case "$1" in *"$needle"*) return 0 ;; esac
    done
    return 1
}

# check_redacted <label> <value>
# Puts <value> in each field of a fixture and renders it. The check passes
# when jq exits 0, no token text remains, and [redacted] appears.
check_redacted() {
    mkjson "S $2" "T $2" "L $2" "D $2" "$TMPROOT/case.json"
    render "$FILTER" "$TMPROOT/case.json"
    if [ "$RENDER_RC" != 0 ]; then
        fail "$1" "jq exit $RENDER_RC"
    elif leaks "$RENDER_OUT"; then
        fail "$1" "token text remains: $RENDER_OUT"
    elif [ "${RENDER_OUT#*\[redacted\]}" = "$RENDER_OUT" ]; then
        fail "$1" "no [redacted] in: $RENDER_OUT"
    else
        pass "$1"
    fi
}

# Scenario 1: the workflow has exactly 3 RENDER_FILTER values.
FDIR="$TMPROOT/filters"
mkdir -p "$FDIR"
count="$(extract_filters "$REVIEW" "$FDIR")"
if [ "$count" != 3 ]; then
    fail "claude-review.yml has 3 RENDER_FILTER values" "found $count"
    harness_report
fi
pass "claude-review.yml has 3 RENDER_FILTER values"

# Scenario 2: the 3 values are byte-identical. A fix in one job only would
# leave the other jobs open.
if cmp -s "$FDIR/filter-1" "$FDIR/filter-2" && cmp -s "$FDIR/filter-1" "$FDIR/filter-3"; then
    pass "the 3 RENDER_FILTER values are byte-identical"
else
    fail "the 3 RENDER_FILTER values are byte-identical" "the values differ"
fi
if [ ! -s "$FDIR/filter-1" ] || ! grep -q 'def redact' "$FDIR/filter-1" \
    || ! grep -q 'def clean' "$FDIR/filter-1"; then
    fail "RENDER_FILTER has def redact and def clean" "extraction is empty or wrong"
    harness_report
fi
FILTER="$(cat "$FDIR/filter-1")"

# render <filter> <json-file>
# Sets RENDER_OUT to the jq -j output and RENDER_RC to the jq exit code.
# The caller must not run it in a subshell, or the variables are lost.
RENDER_RC=0
RENDER_OUT=""
render() {
    # The trailing x<rc> keeps trailing newlines and the exit code from
    # one jq run.
    RENDER_OUT="$(jq -j "$1" "$2" 2>"$TMPROOT/stderr"; echo "x$?")"
    RENDER_RC="${RENDER_OUT##*x}"
    RENDER_OUT="${RENDER_OUT%x*}"
}

# mkjson <summary> <title> <location> <detail> <file>
# Writes a fixture with one finding for each severity. jq --arg builds the
# JSON, so a value needs no quoting.
mkjson() {
    jq -n --arg s "$1" --arg t "$2" --arg l "$3" --arg d "$4" '
        {summary_markdown: $s,
         findings: [("blocking", "important", "note", "suggestion")
                    | {severity: ., title: $t, location: $l, detail: $d}]}' > "$5"
}

# Scenario 3: every token in summary_markdown and in each finding field,
# for each severity. Putting a token in all places catches a filter that
# cleans only some fields.
mkjson "Summary $ALL_TOKENS end" "Title $ALL_TOKENS end" \
    "src/a.sh:1 $ALL_TOKENS end" "Detail $ALL_TOKENS end" "$TMPROOT/all.json"
render "$FILTER" "$TMPROOT/all.json"; out="$RENDER_OUT"
label="all token kinds are redacted in the summary and in each finding field"
if [ "$RENDER_RC" != 0 ]; then
    fail "$label" "jq exit $RENDER_RC: $(cat "$TMPROOT/stderr")"
elif leaks "$out"; then
    fail "$label" "token text remains: $out"
elif [ -z "$out" ]; then
    fail "$label" "the output is empty"
else
    pass "$label"
fi
# 7 tokens, in 1 summary and in 3 fields of 4 findings: 7 * 13 = 91.
n="$(printf '%s' "$out" | grep -o '\[redacted\]' | wc -l | tr -d ' ')"
if [ "$n" = 91 ]; then
    pass "the output has one [redacted] for each token"
else
    fail "the output has one [redacted] for each token" "expected 91, got $n"
fi
# All 4 severities must reach the output, or the loop proves nothing.
for h in Blocking Important Notes Suggestions; do
    case "$out" in
        *"### $h"*) pass "the output has the $h section" ;;
        *) fail "the output has the $h section" "$out" ;;
    esac
done

# Scenario 4: a removed marker joins a token. clean removes <!-- and -->
# and then calls redact, so the joined token must go whole, with its body.
for joined in "ghp_<!---->${ALNUM30}" "gh<!---->p_${ALNUM30}" \
    "ghs<!---->_${ALNUM30}" \
    "github_<!---->pat_${ALNUM30}" "sk-<!---->ant-${ALNUM30}" \
    "ghp<!--<!---->-->_${ALNUM30}"; do
    check_redacted "a joined token is redacted whole: $joined" "$joined"
done

# Scenario 5: a bare prefix with no body. A model can write it, or a
# marker can leave it. The prefix must go.
for p in ghp_ ghs_ gho_ ghu_ ghr_ github_pat_ sk-ant-; do
    check_redacted "a bare $p prefix is redacted" "$p end"
done

# Scenario 6: a finding field of the wrong type. Observed behavior of jq
# 1.8: gsub on a number is a jq error (exit 5), jq -j builds the whole
# string before it prints, so stdout is empty and no token from another
# field is printed. The workflow checks the output shape first with
# VALID_FILTER, so this case should not reach the renderer. The test
# holds the renderer to the same safe result: no token text on stdout.
jq -n --arg t "$B_GHP" '
    {summary_markdown: "ok", findings: [
      {severity: "blocking", title: 42, location: "x", detail: $t}]}' > "$TMPROOT/type.json"
render "$FILTER" "$TMPROOT/type.json"; out="$RENDER_OUT"
label="a number in a finding field prints no token text"
if leaks "$out"; then
    fail "$label" "token text remains: $out"
else
    pass "$label"
fi
if [ "$RENDER_RC" != 0 ]; then
    pass "a number in a finding field makes jq exit non-zero"
else
    fail "a number in a finding field makes jq exit non-zero" "jq exit 0, output: $out"
fi

# Scenario 7: the test can fail. A copy of the filter with redact turned
# into a no-op must leak. The sed changes the one call of redact in clean.
# The copy must differ from the real filter, or the sed matched nothing.
# shellcheck disable=SC2016 # the sed expression is literal
BROKEN="$(printf '%s' "$FILTER" | sed 's/(\$out | redact)/$out/')"
if [ "$BROKEN" = "$FILTER" ]; then
    fail "the no-op redact copy differs from the real filter" "sed changed nothing"
else
    render "$BROKEN" "$TMPROOT/all.json"; out="$RENDER_OUT"
    if [ "$RENDER_RC" = 0 ] && leaks "$out"; then
        pass "a filter with a no-op redact leaks, so the token check can fail"
    else
        fail "a filter with a no-op redact leaks, so the token check can fail" \
            "jq exit $RENDER_RC, leaks: no"
    fi
    # A redact that removes only the prefix must also fail the body check.
    PREFIX_ONLY="$(printf '%s' "$FILTER" | sed 's/gsub("gh\[pousr\]_\[A-Za-z0-9\]{20,}"; "\[redacted\]")/./')"
    render "$PREFIX_ONLY" "$TMPROOT/all.json"; out="$RENDER_OUT"
    if [ "$PREFIX_ONLY" != "$FILTER" ] && [ "$RENDER_RC" = 0 ] && leaks "$out"; then
        pass "a filter without the gh body rule leaks, so the body check can fail"
    else
        fail "a filter without the gh body rule leaks, so the body check can fail" \
            "jq exit $RENDER_RC"
    fi
fi

harness_report
