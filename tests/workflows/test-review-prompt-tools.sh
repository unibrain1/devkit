#!/bin/bash
#
# Tests the tool rules in the review prompts of claude-review.yml (issue
# #54). --allowedTools lets Bash run only "gh pr diff". A prompt that only
# says "Bash, Read, Grep, and Glob are available" can make the model run
# "cd", chained commands, pipes, and "cat". The allowlist refuses each one.
# The review then runs with less input, and the Gate still passes.
#
# So each Claude step prompt must have the ## Tools block: Read with a full
# path for each file, PR context files included, Grep and Glob to search,
# and Bash for one bare "gh pr diff" command. The block also says that Read,
# Grep, and Glob reach only the checkout and the PR context folder (issue
# #47), so the model does not try a path that the allowlist refuses. Each
# "gh pr diff" example in the prompt must be that bare command. The test
# checks the workflow text. It cannot check what the model does.
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
# Prints one line for each problem in a claude-code-action step. Each line
# starts with "<file>:<line>":
#   - The prompt lacks a phrase of the ## Tools block. The check uses the
#     prompt with each line break and its indent as one space, so a re-wrap
#     does not split a phrase.
#   - The prompt has the old "are available here" text.
#   - A line in the file with "gh pr diff" is not the bare command
#     "gh pr diff ${{ <expression> }}". The "Bash runs only" line and the
#     allowlist lines are not checked.
#   - The prompt has no bare "gh pr diff" example, so "exactly as this
#     prompt shows it" points at nothing.
#   - The prompt names merged-prs.txt with no workspace path.
# It also prints "<file>: found N Claude steps" when the file has fewer or
# more than 3 Claude steps. A step ends at the next step ("      - ") or
# the next job.
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
            need("`Read`, `Grep`, and `Glob` reach only the checkout and `${{ runner.temp }}/pr-context`. The allowlist refuses all other paths.")
            need("Bash runs only `gh pr diff <PR number>`")
            need("Type it as one command, exactly as this prompt shows it.")
            need("Do not add `cd`, `;`, `&&`, `|`, `>`, or a second command.")
            need("The allowlist refuses all other Bash commands.")
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

# An awk error writes only to stderr. So the check keeps stderr and treats a
# non-zero exit as a problem, or a broken awk program would pass.
# run_check <file>: sets $problems to the check output, or to the error.
run_check() {
    if ! problems="$(check_file "$1" 2>&1)"; then
        problems="check_file failed: ${problems:-no output}"
    fi
    details=()
    while IFS= read -r p; do details+=("$p"); done <<< "$problems"
}

label="each review prompt has the tool rules and bare gh pr diff examples"
if [ ! -f "$REVIEW" ]; then
    fail "$label" "no file $REVIEW"
else
    run_check "$REVIEW"
    if [ -z "$problems" ]; then
        pass "$label"
    else
        fail "$label" "${details[@]}"
    fi
fi

# Each fixture is a copy of the workflow with one defect. The check must
# report each one with the reason that belongs to it. A fixture can also
# trip another check, so any output alone does not prove the check works.
# defect <name> <reason> <sed expression>: writes the fixture and checks it.
defect() {
    sed "$3" "$REVIEW" > "$TMPROOT/$1.yml"
    check_fixture "$1" "$2"
}
# check_fixture <name> <reason>
check_fixture() {
    label="the check reports a fixture with $1"
    run_check "$TMPROOT/$1.yml"
    case "$problems" in
        "check_file failed:"*) fail "$label" "${details[@]}" ;;
        *"$2"*) pass "$label" ;;
        "") fail "$label" "check_file did not print: $2" "it printed nothing" ;;
        *) fail "$label" "check_file did not print: $2" "it printed:" "${details[@]}" ;;
    esac
}
# shellcheck disable=SC2016 # the sed expressions match literal workflow text
if [ -f "$REVIEW" ]; then
    defect "no Tools block" "lacks: ## Tools" 's/## Tools/## Notes/'
    defect "the old tool text" "old are-available-here text" 's/^            ## Tools$/            Only `Bash`, `Read`, `Grep`, and `Glob` are available here./'
    defect "a gh pr diff pipe" "is not one bare command" 's/^\( *gh pr diff \${{ [a-z_.]* }}\)$/\1 | head/'
    defect "a cd before gh pr diff" "is not one bare command" 's/^\( *\)\(gh pr diff \${{ [a-z_.]* }}\)$/\1cd \/tmp; \2/'
    defect "a bare merged-prs.txt path" "no workspace path" 's/`${{ github.workspace }}\/merged-prs.txt`/`merged-prs.txt`/'
    defect "no path-limit bullet" "lacks: \`Read\`, \`Grep\`, and \`Glob\` reach only" 's/reach only the checkout/reach the checkout/'
    # Only the third prompt loses the bullet.
    awk '/reach only the checkout and$/ && ++n == 3 { sub(/only /, "") } { print }' \
        "$REVIEW" > "$TMPROOT/one prompt with no path-limit bullet.yml"
    check_fixture "one prompt with no path-limit bullet" "lacks: \`Read\`, \`Grep\`, and \`Glob\` reach only"
    defect "no runner.temp path" "lacks: This includes" 's/This includes `${{ runner.temp }}/This includes `/'
    # Only the second prompt loses its Tools block. The check must look at
    # each prompt, not at the file as a whole.
    awk '/^            ## Tools$/ && ++n == 2 { sub(/## Tools/, "## Notes") } { print }' \
        "$REVIEW" > "$TMPROOT/one prompt with no Tools block.yml"
    check_fixture "one prompt with no Tools block" "lacks: ## Tools"
    defect "no gh pr diff example" "no bare gh pr diff example" '/^ *gh pr diff \${{ [a-z_.]* }}$/d'
    # Only the second prompt loses its example, so the count must reset at
    # each step.
    awk '/^ *gh pr diff \$\{\{ [a-z_.]* \}\}$/ && ++n == 2 { next } { print }' \
        "$REVIEW" > "$TMPROOT/one prompt with no gh pr diff example.yml"
    check_fixture "one prompt with no gh pr diff example" "no bare gh pr diff example"
    # A new step with only a uses: line, before the first Claude step.
    awk '/^      - name: Run Claude Issue-Level Review$/ {
        print "      - name: Extra Claude step"
        print "        uses: anthropics/claude-code-action@x"
    } { print }' "$REVIEW" > "$TMPROOT/a fourth Claude step.yml"
    check_fixture "a fourth Claude step" "found 4 Claude steps"
fi

harness_report
