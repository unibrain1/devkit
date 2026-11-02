#!/bin/bash
#
# Tests that the commands with a list of decisions ask all of them in one
# round, not one at a time. Each decision step is checked on its own:
#   review-pr.md            "## Step 6: Handle findings"
#   address-pr-comments.md  "## Step 5: Fix Blocking Items"
#                           "## Step 7: Present Advisory Items"
#   finish-milestone.md     "### Step 6.5: Release retrospective ..."
#   execute-plan.md         "### Step 3: Re-Verify Checklist Against Repo State"
#                           "### Step 6.6: Cleanup Ledger Check"
#                           "### Step 8: Confirm Plan Completeness"
# Each step must cite the skill's "Decision rounds" section, state the
# limit of at most 4 questions in one call, put the "(Recommended)" option
# first, and act only after the last call. A step that can need more than
# one call must also forbid other work between the calls. No command in
# the folder may tell the model to ask one item at a time. The test also
# checks the "## Decision rounds" section of the workflow skill's review.md.
#
# The checks are phrase checks on the command text. They cannot check what
# a model does at run time.
#
# COMMANDS_DIR points the test at a copy of plugins/flow/commands, and
# SKILL_FILE at a copy of the skill's review.md.
#
# Usage: bash tests/commands/test-decision-rounds.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# shellcheck disable=SC2016 # the backticks are Markdown text, not commands
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_DIR="${COMMANDS_DIR:-$REAL_REPO/plugins/flow/commands}"
SKILL_FILE="${SKILL_FILE:-$REAL_REPO/plugins/flow/skills/workflow/references/review.md}"

# Text that tells the model to ask, or act, one item at a time.
SEQUENTIAL='one at a time|one by one|in turn|continue to the next|before (you ask|moving to) the next'

# section <file> <heading>
# Prints the section that starts at the line <heading> and ends before the
# next heading of the same or a higher level.
section() {
    awk -v h="$2" '
        function level(s) { match(s, /^#+/); return RLENGTH }
        $0 == h { on = 1; lv = level($0); print; next }
        on && /^#+ / && level($0) <= lv { exit }
        on { print }
    ' "$1"
}

# bad_step <file> <heading> <calls>
# Prints one line for each round rule that the step breaks. <calls> is
# "many" when the step can need more than one AskUserQuestion call, and
# "one" otherwise. No output means that the step passes.
bad_step() {
    local text
    text=$(section "$1" "$2")
    if [ -z "$text" ]; then
        echo "no section '$2'"
        return
    fi
    if ! printf '%s\n' "$text" | grep -q 'references/review.md' ||
        ! printf '%s\n' "$text" | grep -q '"Decision rounds"'; then
        echo "$2: no citation of references/review.md, \"Decision rounds\""
    fi
    printf '%s\n' "$text" | grep -q 'at most 4' || echo "$2: no 'at most 4' limit"
    printf '%s\n' "$text" | grep -qF '(Recommended)' || echo "$2: no '(Recommended)' option"
    printf '%s\n' "$text" | grep -qE 'after the (last )?call' || echo "$2: does not act after the last call"
    if [ "$3" = many ]; then
        printf '%s\n' "$text" | grep -qE '([Dd]o|with) no other work between the calls' ||
            echo "$2: does not forbid other work between the calls"
    else
        printf '%s\n' "$text" | grep -q 'one AskUserQuestion call' ||
            echo "$2: does not ask in one AskUserQuestion call"
    fi
}

# bad_sequential <file>
# Prints each line of <file> that tells the model to ask one at a time.
bad_sequential() {
    grep -inE "$SEQUENTIAL" "$1" | sed 's/^/asks one at a time: /'
}

# bad_commands <dir>
# Runs every check on the commands in <dir>.
bad_commands() {
    bad_step "$1/review-pr.md" '## Step 6: Handle findings' many
    bad_step "$1/address-pr-comments.md" '## Step 5: Fix Blocking Items' many
    bad_step "$1/address-pr-comments.md" '## Step 7: Present Advisory Items' many
    bad_step "$1/finish-milestone.md" '### Step 6.5: Release retrospective — three questions' one
    bad_step "$1/execute-plan.md" '### Step 3: Re-Verify Checklist Against Repo State' many
    bad_step "$1/execute-plan.md" '### Step 6.6: Cleanup Ledger Check' many
    bad_step "$1/execute-plan.md" '### Step 8: Confirm Plan Completeness' many
    for file in "$1"/*.md; do
        bad_sequential "$file"
    done
}

# bad_skill <file>
# Prints one line for each rule that <file> breaks. The "## Decision rounds"
# section states the limit and the recommended option, and the file does
# not say that review-pr asks one Recommendation at a time.
bad_skill() {
    local text
    text=$(section "$1" '## Decision rounds')
    if [ -z "$text" ]; then
        echo 'no "## Decision rounds" section'
        return
    fi
    printf '%s\n' "$text" | grep -q 'at most 4' || echo "Decision rounds: no 'at most 4' limit"
    printf '%s\n' "$text" | grep -qF '(Recommended)' || echo "Decision rounds: no '(Recommended)' option"
    if grep -qi 'one Recommendation at a time' "$1"; then
        echo "says one Recommendation at a time"
    fi
}

# --- The real files ---

out=$(bad_commands "$COMMANDS_DIR")
if [ -z "$out" ]; then
    pass "each decision step asks its decisions in one round"
else
    fail "each decision step asks its decisions in one round" "$out"
fi

out=$(bad_skill "$SKILL_FILE")
if [ -z "$out" ]; then
    pass "the skill states the Decision rounds rule"
else
    fail "the skill states the Decision rounds rule" "$out"
fi

# --- Fixtures: each check can fail ---

# harness.sh removes $TMPROOT on exit.
TMPROOT=$(mktemp -d)

# mutate <name> <file> <sed-script>
# Copies the commands to $TMPROOT/<name>, and edits <file> there with
# <sed-script>. Prints the new folder.
mutate() {
    local dir="$TMPROOT/$1"
    mkdir -p "$dir"
    cp "$COMMANDS_DIR"/*.md "$dir/"
    sed "$3" "$COMMANDS_DIR/$2" > "$dir/$2"
    echo "$dir"
}

# expect_fail <label> <pattern> <dir>
# Passes when bad_commands on <dir> prints a line that matches <pattern>.
expect_fail() {
    if bad_commands "$3" | grep -qE "$2"; then
        pass "$1"
    else
        fail "$1"
    fi
}

dir=$(mutate walk review-pr.md '/^\*\*If there are Recommendation items:\*\*$/a\
Walk them one at a time, not as a single batch ask.
')
expect_fail "review-pr.md that walks items one at a time fails" 'asks one at a time' "$dir"

dir=$(mutate turn finish-milestone.md 's/^Ask the three questions in one/Ask each question in turn, in one/')
expect_fail "finish-milestone.md that asks each question in turn fails" 'asks one at a time' "$dir"

dir=$(mutate next address-pr-comments.md '/^After the last call, act on each answer in item order:$/i\
Continue to the next Advisory item.
')
expect_fail "address-pr-comments.md that continues to the next item fails" 'asks one at a time' "$dir"

# Step 5 keeps the limit, so only a check of Step 7 alone can see this.
dir=$(mutate step7-limit address-pr-comments.md '/^## Step 7/,/^## Step 8/s/at most 4/up to four/')
expect_fail "address-pr-comments.md Step 7 with no 'at most 4' fails" 'Step 7.*at most 4' "$dir"

dir=$(mutate work review-pr.md 's/Do no other work between the calls\.//')
expect_fail "review-pr.md that allows work between the calls fails" 'other work between the calls' "$dir"

dir=$(mutate act review-pr.md 's/after the last call/after each answer/g')
expect_fail "review-pr.md that acts before the last call fails" 'act after the last call' "$dir"

dir=$(mutate calls finish-milestone.md 's/in one AskUserQuestion call/in three AskUserQuestion calls/')
expect_fail "finish-milestone.md that asks in three calls fails" 'one AskUserQuestion call' "$dir"

dir=$(mutate may review-pr.md 's/Do no other work between the calls\./You may do other work between the calls./')
expect_fail "review-pr.md that allows other work between the calls fails" 'other work between the calls' "$dir"

dir=$(mutate ledger execute-plan.md 's/^  - Collect every new item before you ask\.$/  - Ask about the items one at a time./')
expect_fail "execute-plan.md that asks one ledger item at a time fails" 'asks one at a time' "$dir"

# Step 6.6 keeps the limit, so only a check of Step 8 alone can see this.
dir=$(mutate step8-limit execute-plan.md '/^### Step 8/,/^### Step 9/s/at most 4/up to four/')
expect_fail "execute-plan.md Step 8 with no 'at most 4' fails" 'Step 8.*at most 4' "$dir"

# A command outside the decision steps gets the phrase check too.
dir=$(mutate other commit-push-pr.md 's/in two separate Bash calls:/one at a time:/')
expect_fail "commit-push-pr.md with one-at-a-time wording fails" 'asks one at a time' "$dir"

dir=$(mutate rec finish-milestone.md 's/(Recommended)/(Preferred)/g')
expect_fail "finish-milestone.md with no '(Recommended)' option fails" 'Recommended' "$dir"

dir=$(mutate cite review-pr.md 's/references\/review\.md`, "Decision rounds"/references\/review.md`/')
expect_fail "review-pr.md with no Decision rounds citation fails" 'no citation' "$dir"

dir=$(mutate heading address-pr-comments.md 's/^## Step 7: Present Advisory Items$/## Step 7: Advisory/')
expect_fail "address-pr-comments.md with a renamed Step 7 fails" 'no section' "$dir"

grep -v '^## Decision rounds$' "$SKILL_FILE" > "$TMPROOT/no-section.md"
if bad_skill "$TMPROOT/no-section.md" | grep -q 'no "## Decision rounds" section'; then
    pass "review.md with no Decision rounds section fails"
else
    fail "review.md with no Decision rounds section fails"
fi

# The limit in another section of review.md does not count.
awk '/^## / { on = ($0 == "## Decision rounds") }
     on { gsub(/at most 4/, "up to four") } { print }
     END { print "## Other"; print "at most 4" }' "$SKILL_FILE" > "$TMPROOT/limit-elsewhere.md"
if bad_skill "$TMPROOT/limit-elsewhere.md" | grep -q "no 'at most 4' limit"; then
    pass "review.md with the limit outside Decision rounds fails"
else
    fail "review.md with the limit outside Decision rounds fails"
fi

{ cat "$SKILL_FILE"; echo '- `/flow:review-pr` asks about one Recommendation at a time.'; } \
    > "$TMPROOT/one-recommendation.md"
if bad_skill "$TMPROOT/one-recommendation.md" | grep -q 'one Recommendation at a time'; then
    pass "review.md that asks one Recommendation at a time fails"
else
    fail "review.md that asks one Recommendation at a time fails"
fi

harness_report
