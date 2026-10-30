#!/bin/bash
#
# Tests the tool rules in the review prompts of claude-review.yml (issue
# #54). --allowedTools lets Bash run only "gh pr diff". A prompt that only
# says "Bash, Read, Grep, and Glob are available" leads the model to "cd",
# ";", pipes, and "cat", and the allowlist refuses each one. The review then
# runs with less input and the Gate still passes.
#
# So each Claude step prompt must have the ## Tools block: Read with a full
# path for each file, PR context files included, Grep and Glob to search,
# and Bash for one bare "gh pr diff" command. Each "gh pr diff" example in
# the prompt must be that bare command. The test checks the workflow text.
# It cannot check what the model does.
#
# WORKFLOW_DIR points the test at a copy of .github/workflows.
#
# Usage: bash tests/workflows/test-review-prompt-tools.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW_DIR="${WORKFLOW_DIR:-$REAL_REPO/.github/workflows}"
REVIEW="$WORKFLOW_DIR/claude-review.yml"

# check_file <file>
# Prints "<file>:<line> <reason>" for each problem in a claude-code-action
# step:
#   - The prompt lacks a phrase of the ## Tools block. The check uses the
#     prompt with each line break and its indent as one space, so a re-wrap
#     does not split a phrase.
#   - The prompt has the old "are available here" text.
#   - A prompt line with "gh pr diff" is not the bare command
#     "gh pr diff ${{ <expression> }}", other than the "Bash runs only"
#     line and the allowlist lines. Or the prompt has no bare "gh pr diff" example, so "exactly as
#     this prompt shows it" points at nothing.
#   - The prompt names merged-prs.txt with no workspace path.
# It also prints a problem when the file has fewer or more than 3 Claude
# steps. A step ends at the next step ("      - ") or the next job.
check_file() {
    awk -v file="$1" '
        function need(text) {
            if (!index(flat, text)) print file ":" c " Claude step lacks: " text
        }
        function close_claude() {
            if (!c) return
            steps++
            flat = seg; gsub(/\n */, " ", flat)
            need("## Tools")
            need("Read each file with the `Read` tool. Give it the full path.")
            need("This includes `${{ runner.temp }}/pr-context/pr.json` and `${{ runner.temp }}/pr-context/comments.jsonl`.")
            need("The checkout is at `${{ github.workspace }}`.")
            need("Search with `Grep`. List files with `Glob`.")
            need("Bash runs only `gh pr diff <PR number>`")
            need("Type it as one command, exactly as this prompt shows it.")
            need("Do not add `cd`, `;`, `&&`, `|`, `>`, or a second command.")
            need("Do not use `cat`, `ls`, `head`, `find`, or `grep` in Bash.")
            if (!examples)
                print file ":" c " Claude step has no bare gh pr diff example"
            if (index(flat, "are available here"))
                print file ":" c " Claude step has the old are-available-here text"
            if (index(flat, "merged-prs.txt") && !index(flat, "`${{ github.workspace }}/merged-prs.txt`"))
                print file ":" c " Claude step names merged-prs.txt with no workspace path"
            c = 0
        }
        /^      - / || /^  [^ ]/ { close_claude() }
        /^      - / { start = NR; seg = ""; examples = 0 }
        { seg = seg "\n" $0 }
        /uses: anthropics\/claude-code-action@/ { c = start }
        /gh pr diff/ && !/allowedTools|Bash\(gh pr diff:\*\)|Bash runs only/ {
            line = $0; sub(/^ +/, "", line)
            if (line !~ /^gh pr diff \$\{\{ [a-z_.]+ \}\}$/)
                print file ":" NR " gh pr diff is not one bare command: " line
            else
                examples++
        }
        END {
            close_claude()
            if (steps != 3) print file ": found " steps + 0 " Claude steps, want 3"
        }
    ' "$1"
}

TMPROOT="$(mktemp -d)"

label="each review prompt has the tool rules and bare gh pr diff examples"
if [ ! -f "$REVIEW" ]; then
    fail "$label" "no file $REVIEW"
else
    problems="$(check_file "$REVIEW")"
    if [ -z "$problems" ]; then
        pass "$label"
    else
        details=()
        while IFS= read -r p; do details+=("$p"); done <<< "$problems"
        fail "$label" "${details[@]}"
    fi
fi

# Each fixture is a copy of the workflow with one defect. The check must
# report each one, or it could pass on a prompt with the defect.
# defect <name> <sed expression>: writes the fixture and checks it.
defect() {
    sed "$2" "$REVIEW" > "$TMPROOT/$1.yml"
    check_fixture "$1"
}
check_fixture() {
    label="the check reports a fixture with $1"
    if [ -n "$(check_file "$TMPROOT/$1.yml")" ]; then
        pass "$label"
    else
        fail "$label" "check_file printed nothing"
    fi
}
# shellcheck disable=SC2016 # the sed expressions match literal workflow text
if [ -f "$REVIEW" ]; then
    defect "no Tools block" 's/## Tools/## Notes/'
    defect "the old tool text" 's/^            ## Tools$/            Only `Bash`, `Read`, `Grep`, and `Glob` are available here./'
    defect "a gh pr diff pipe" 's/^\( *gh pr diff \${{ [a-z_.]* }}\)$/\1 | head/'
    defect "a cd before gh pr diff" 's/^\( *\)\(gh pr diff \${{ [a-z_.]* }}\)$/\1cd \/tmp; \2/'
    defect "a bare merged-prs.txt path" 's/`${{ github.workspace }}\/merged-prs.txt`/`merged-prs.txt`/'
    defect "no runner.temp path" 's/This includes `${{ runner.temp }}/This includes `/'
    # Only the second prompt loses its Tools block. The check must look at
    # each prompt, not at the file as a whole.
    awk '/^            ## Tools$/ && ++n == 2 { sub(/## Tools/, "## Notes") } { print }' \
        "$REVIEW" > "$TMPROOT/one prompt with no Tools block.yml"
    check_fixture "one prompt with no Tools block"
    defect "no gh pr diff example" '/^ *gh pr diff \${{ [a-z_.]* }}$/d'
    # Only the second prompt loses its example, so the count must reset at
    # each step.
    awk '/^ *gh pr diff \$\{\{ [a-z_.]* \}\}$/ && ++n == 2 { next } { print }' \
        "$REVIEW" > "$TMPROOT/one prompt with no gh pr diff example.yml"
    check_fixture "one prompt with no gh pr diff example"
    # A new step with only a uses: line, before the first Claude step.
    awk '/^      - name: Run Claude Issue-Level Review$/ {
        print "      - name: Extra Claude step"
        print "        uses: anthropics/claude-code-action@x"
    } { print }' "$REVIEW" > "$TMPROOT/a fourth Claude step.yml"
    check_fixture "a fourth Claude step"
fi

harness_report
