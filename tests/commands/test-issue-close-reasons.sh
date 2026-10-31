#!/bin/bash
#
# Tests that each "gh issue close" in the flow commands records why the
# issue closed. With no --reason, GitHub records "completed", also for
# culled work that did not ship. A cull close must also remove the
# milestone in the same step, because a milestone shows only open work and
# shipped work. Only shipped work closes as "completed", and it keeps its
# milestone. The test also checks that the workflow skill says what each
# reason means.
#
# The test reads only the fenced code blocks of the commands. A
# "gh issue close" in prose is not a command that the model runs. A
# "gh issue close" in a shell comment in a code block counts as a close, so
# the check fails on it.
#
# COMMANDS_DIR points the test at a copy of plugins/flow/commands, and
# SKILL_FILE at a copy of the skill's github.md.
#
# Usage: bash tests/commands/test-issue-close-reasons.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# shellcheck disable=SC2016 # the backticks are Markdown text, not commands
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_DIR="${COMMANDS_DIR:-$REAL_REPO/plugins/flow/commands}"
SKILL_FILE="${SKILL_FILE:-$REAL_REPO/plugins/flow/skills/workflow/references/github.md}"

# closes <file>
# Prints "<line>\t<previous>\t<command>" for each "gh issue close" in a
# fenced code block (``` or ~~~) of <file>. A line that ends in "\" joins
# the next line, so a flag on a continuation line counts. <line> is the
# first line of the command. <previous> is the command or comment directly
# before it in the same code block, blank lines not counted.
closes() {
    awk '
        /^[ \t]*(```|~~~)/ { in_code = !in_code; cmd = ""; prev = ""; next }
        !in_code { next }
        /^[ \t]*$/ { next }
        {
            line = $0
            if (cmd == "") start = NR
            if (sub(/\\[ \t]*$/, "", line)) { cmd = cmd line " "; next }
            cmd = cmd line
            if (cmd ~ /gh issue close/) print start "\t" prev "\t" cmd
            prev = cmd
            cmd = ""
        }
    ' "$1"
}

# check_closes <file-name>
# Reads the output of closes on stdin. Prints "<file-name>:<line> <reason>"
# for each close that breaks a rule. A double-quoted --comment or --body
# value does not count, so a reason flag in that text is not a reason. The
# rules:
#   1. A close has a reason: --reason "completed", --reason "not planned",
#      --reason "duplicate", or --duplicate-of <N>.
#   2. Only finish-issue.md closes shipped work as "completed".
#   3. Each other close is a cull. Its milestone step is the line before it:
#      a "gh issue edit" with --remove-milestone for the same issue, or a
#      "# No milestone to remove:" comment that says why the issue has no
#      milestone.
#   4. A completed close does not follow a step that removes the milestone
#      (--remove-milestone or --milestone "") for the same issue. A shipped
#      issue keeps its milestone, or the release scope and the milestone
#      counts are wrong.
check_closes() {
    awk -F '\t' -v file="$1" '
        function strip(s) { gsub(/--(comment|body) "[^"]*"/, "", s); return s }
        # target("gh issue close NNN --repo ...") is "NNN".
        function target(s,    t) {
            if (!match(s, /gh issue (close|edit) [^ ]+/)) return ""
            t = substr(s, RSTART, RLENGTH)
            sub(/.* /, "", t)
            return t
        }
        {
            cmd = strip($3)
            prev = strip($2)
            completed = cmd ~ /--reason "completed"/
            cull = cmd ~ /--reason "(not planned|duplicate)"/ || cmd ~ /--duplicate-of [^ ]/
            if (!completed && !cull)
                print file ":" $1 " no valid --reason or --duplicate-of"
            if (completed && file != "finish-issue.md")
                print file ":" $1 " completed close outside finish-issue.md"
            if (!completed &&
                !(prev ~ /gh issue edit/ && prev ~ /--remove-milestone/ && target(prev) == target(cmd)) &&
                prev !~ /^[ \t]*# No milestone to remove:/)
                print file ":" $1 " cull close with no milestone step before it"
            if (completed &&
                prev ~ /gh issue edit/ && target(prev) == target(cmd) &&
                (prev ~ /--remove-milestone/ || prev ~ /--milestone ""/))
                print file ":" $1 " completed close removes the milestone"
        }
    '
}

# bad_closes <file>
# Runs closes and check_closes on <file>.
bad_closes() {
    closes "$1" | check_closes "$(basename "$1")"
}

# bad_skill <file>
# Prints one line for each rule that the "## Close reasons" section of
# <file> breaks, or one line when the section is absent. The section names
# each reason. Its `completed` row says that the issue keeps its milestone,
# and the `not planned` and `duplicate` rows say to remove it.
bad_skill() {
    awk '
        /^## / { in_section = ($0 == "## Close reasons"); if (in_section) found = 1; next }
        !in_section { next }
        { text = text $0 "\n" }
        /^\| `completed` / { completed_row = $0 }
        /^\| `not planned` / { not_planned_row = $0 }
        /^\| `duplicate` / { duplicate_row = $0 }
        END {
            if (!found) { print "no \"## Close reasons\" section"; exit }
            if (text !~ /`completed`/) print "\"## Close reasons\" does not name `completed`"
            if (text !~ /`not planned`/) print "\"## Close reasons\" does not name `not planned`"
            if (text !~ /`duplicate`/) print "\"## Close reasons\" does not name `duplicate`"
            if (completed_row !~ /keeps/) print "the `completed` row does not say that the issue keeps its milestone"
            if (not_planned_row !~ /Remove/) print "the `not planned` row does not say to remove the milestone"
            if (duplicate_row !~ /Remove/) print "the `duplicate` row does not say to remove the milestone"
        }
    ' "$1"
}

total=0
# A file that awk cannot read prints nothing, which looks the same as a file
# with no closes. So each read error fails here, not only through the count.
for path in "$COMMANDS_DIR"/*.md; do
    f="$(basename "$path")"
    if ! found="$(closes "$path")"; then
        fail "$f: the test can read the command file" "$path"
        continue
    fi
    [ -z "$found" ] && continue
    n="$(printf '%s\n' "$found" | grep -c .)"
    total=$((total + n))
    bad="$(printf '%s\n' "$found" | check_closes "$f")"
    if [ -z "$bad" ]; then
        pass "$f: $n close(s) with a reason and a milestone step"
    else
        fail "$f: each close has a reason and a milestone step" "$bad"
    fi
done

# The commands have 6 closes today: 1 in plan-milestone, 2 in
# start-milestone, 2 in groom-backlog, and 1 in finish-issue. A new close
# changes this count, so the person who adds it reads this test.
if [ "$total" -eq 6 ]; then
    pass "6 gh issue close commands in total"
else
    fail "6 gh issue close commands in total" "found $total"
fi

if closes "$COMMANDS_DIR/finish-issue.md" | grep -q -- '--reason "completed"'; then
    pass "finish-issue.md closes shipped work as completed"
else
    fail "finish-issue.md closes shipped work as completed"
fi

if ! bad="$(bad_skill "$SKILL_FILE")"; then
    fail "github.md says what each close reason means" "cannot read $SKILL_FILE"
elif [ -z "$bad" ]; then
    pass "github.md says what each close reason means"
else
    fail "github.md says what each close reason means" "$bad"
fi

TMPROOT="$(mktemp -d)"

# accepted <file>
# True when closes finds exactly one close in <file> and check_closes accepts
# it. An empty bad_closes alone also passes when closes finds nothing.
accepted() {
    [ "$(closes "$1" | grep -c .)" -eq 1 ] && [ -z "$(bad_closes "$1")" ]
}

# fixture <name> <body> [file-name]
# Writes $TMPROOT/<name>/<file-name> (default command.md), a command file
# with one fenced code block that holds <body>.
fixture() {
    mkdir -p "$TMPROOT/$1"
    printf '# Fixture\n\n```bash\n%s\n```\n' "$2" > "$TMPROOT/$1/${3:-command.md}"
}

# A close with no reason must fail the check.
fixture no-reason 'gh issue edit 1 --remove-milestone
gh issue close 1 --comment "Closing."'
if bad_closes "$TMPROOT/no-reason/command.md" | grep -q 'no valid --reason'; then
    pass "a close with no reason fails the check"
else
    fail "a close with no reason fails the check"
fi

# A reason on a continuation line must pass.
fixture continuation 'gh issue edit 1 --remove-milestone
gh issue close 1 \
  --reason "not planned" \
  --comment "Closing."'
if accepted "$TMPROOT/continuation/command.md"; then
    pass "a reason on a continuation line passes"
else
    fail "a reason on a continuation line passes" "$(bad_closes "$TMPROOT/continuation/command.md")"
fi

# --duplicate-of sets the reason duplicate, so it must pass.
fixture duplicate 'gh issue edit 1 --remove-milestone
gh issue close 1 --duplicate-of 2 --comment "Consolidated into #2."'
if accepted "$TMPROOT/duplicate/command.md"; then
    pass "--duplicate-of passes as a reason"
else
    fail "--duplicate-of passes as a reason" "$(bad_closes "$TMPROOT/duplicate/command.md")"
fi

# A close in prose is not a command, so it must not fail the check.
mkdir -p "$TMPROOT/prose"
printf '# Fixture\n\nDo not run `gh issue close` with no reason.\n' > "$TMPROOT/prose/command.md"
if [ -z "$(bad_closes "$TMPROOT/prose/command.md")" ]; then
    pass "a close in prose does not fail the check"
else
    fail "a close in prose does not fail the check"
fi

# A cull close with no milestone step must fail the check, also when a
# milestone edit is in the same code block but not directly before it.
fixture no-milestone 'gh issue edit 1 --remove-milestone
gh issue comment 2 --body "Moved."
gh issue close 2 --reason "not planned"'
if bad_closes "$TMPROOT/no-milestone/command.md" | grep -q 'no milestone step'; then
    pass "a cull close with no milestone step fails the check"
else
    fail "a cull close with no milestone step fails the check"
fi

# The no-milestone note directly before a close must pass.
fixture note '# No milestone to remove: these issues have no milestone.
gh issue close 1 --reason "not planned"'
if accepted "$TMPROOT/note/command.md"; then
    pass "the no-milestone note passes as a milestone step"
else
    fail "the no-milestone note passes as a milestone step" "$(bad_closes "$TMPROOT/note/command.md")"
fi

# A completed close in finish-issue.md keeps its milestone, so it needs no
# milestone step.
fixture completed 'gh issue close 1 --reason "completed" --comment "Resolved via PR #2."' finish-issue.md
if accepted "$TMPROOT/completed/finish-issue.md"; then
    pass "a completed close in finish-issue.md needs no milestone step"
else
    fail "a completed close in finish-issue.md needs no milestone step" "$(bad_closes "$TMPROOT/completed/finish-issue.md")"
fi

# A completed close in another file is a cull that GitHub records as
# shipped, so it must fail the check.
fixture completed-cull 'gh issue edit 1 --remove-milestone
gh issue close 1 --reason "completed"'
if bad_closes "$TMPROOT/completed-cull/command.md" | grep -q 'completed close outside finish-issue.md'; then
    pass "a completed close outside finish-issue.md fails the check"
else
    fail "a completed close outside finish-issue.md fails the check"
fi

# A completed close in finish-issue.md must not follow a step that removes
# the milestone of the same issue, in either form of the flag.
fixture completed-removes-milestone 'gh issue edit 1 --remove-milestone
gh issue close 1 --reason "completed"' finish-issue.md
if bad_closes "$TMPROOT/completed-removes-milestone/finish-issue.md" | grep -q 'completed close removes the milestone'; then
    pass "a completed close after --remove-milestone fails the check"
else
    fail "a completed close after --remove-milestone fails the check"
fi
fixture completed-empty-milestone 'gh issue edit 1 --milestone ""
gh issue close 1 --reason "completed"' finish-issue.md
if bad_closes "$TMPROOT/completed-empty-milestone/finish-issue.md" | grep -q 'completed close removes the milestone'; then
    pass "a completed close after --milestone \"\" fails the check"
else
    fail "a completed close after --milestone \"\" fails the check"
fi

# A milestone edit for a different issue does not break the completed rule.
fixture completed-other-edit 'gh issue edit 999 --remove-milestone
gh issue close 1 --reason "completed"' finish-issue.md
if accepted "$TMPROOT/completed-other-edit/finish-issue.md"; then
    pass "a milestone removal for a different issue does not fail a completed close"
else
    fail "a milestone removal for a different issue does not fail a completed close" "$(bad_closes "$TMPROOT/completed-other-edit/finish-issue.md")"
fi

# A reason flag in the comment text is not a reason. A double-quoted
# comment cannot hold --reason "<value>" with its quotes, so the fixture
# uses --duplicate-of.
fixture reason-in-comment 'gh issue edit 1 --remove-milestone
gh issue close 1 --comment "Closed. Use --duplicate-of 2 if it comes back."'
if bad_closes "$TMPROOT/reason-in-comment/command.md" | grep -q 'no valid --reason'; then
    pass "a reason flag in the comment text fails the check"
else
    fail "a reason flag in the comment text fails the check"
fi

# A reason that gh does not know must fail the check.
fixture bad-value 'gh issue edit 1 --remove-milestone
gh issue close 1 --reason "bogus"'
if bad_closes "$TMPROOT/bad-value/command.md" | grep -q 'no valid --reason'; then
    pass "an unknown reason fails the check"
else
    fail "an unknown reason fails the check"
fi

# A milestone edit for a different issue is not a milestone step.
fixture other-issue 'gh issue edit 999 --remove-milestone
gh issue close NNN --reason "not planned"'
if bad_closes "$TMPROOT/other-issue/command.md" | grep -q 'no milestone step'; then
    pass "a milestone edit for a different issue fails the check"
else
    fail "a milestone edit for a different issue fails the check"
fi

# A close in a ~~~ fence is a command too.
mkdir -p "$TMPROOT/tilde"
printf '# Fixture\n\n~~~bash\ngh issue close 1\n~~~\n' > "$TMPROOT/tilde/command.md"
if bad_closes "$TMPROOT/tilde/command.md" | grep -q 'no valid --reason'; then
    pass "a close with no reason in a ~~~ fence fails the check"
else
    fail "a close with no reason in a ~~~ fence fails the check"
fi

# The finish-issue.md check reads the closes output. With no
# --reason "completed" in finish-issue.md, that output has no completed reason.
sed 's/ --reason "completed"//' "$COMMANDS_DIR/finish-issue.md" > "$TMPROOT/finish-issue.md"
if [ ! -s "$TMPROOT/finish-issue.md" ]; then
    fail "closes finds no completed reason after the sed edit" "cannot read $COMMANDS_DIR/finish-issue.md"
elif closes "$TMPROOT/finish-issue.md" | grep -q -- '--reason "completed"'; then
    fail "closes finds no completed reason after the sed edit"
else
    pass "closes finds no completed reason after the sed edit"
fi

# A github.md with no "## Close reasons" section, or with a reason absent
# from it, must fail the check.
grep -v '^## Close reasons$' "$SKILL_FILE" > "$TMPROOT/no-section.md"
if bad_skill "$TMPROOT/no-section.md" | grep -q 'no "## Close reasons" section'; then
    pass "a github.md with no Close reasons section fails the check"
else
    fail "a github.md with no Close reasons section fails the check"
fi
sed 's/`not planned`/`unplanned`/g' "$SKILL_FILE" > "$TMPROOT/no-reason.md"
if bad_skill "$TMPROOT/no-reason.md" | grep -q '`not planned`'; then
    pass "a Close reasons section with no \`not planned\` fails the check"
else
    fail "a Close reasons section with no \`not planned\` fails the check"
fi

# A Close reasons table that keeps the milestone on a cull must fail the
# check.
sed '/^| `not planned` /s/Remove it in the same step\./Keep it./' "$SKILL_FILE" > "$TMPROOT/keep.md"
if bad_skill "$TMPROOT/keep.md" | grep -q '`not planned` row'; then
    pass "a not planned row that keeps the milestone fails the check"
else
    fail "a not planned row that keeps the milestone fails the check"
fi

harness_report
