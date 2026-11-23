#!/bin/bash
#
# Tests the text of /flow:new-project and the plugin step of /flow:setup.
#
# new-project.md must list the six families in the first-match order of the
# family rule. docs/families.md "Choose a family" and `flow-template --list`
# must give the same order. The command must ask for approval before it
# runs `gh repo create`, `git commit`, and `git push`, and it must never
# run a command with `--force`. It must name each flow-template mode and
# each setup script, and the manual steps. It has no Step 0 and no
# `model:` key. "## Step 2" must name the seven setup topics and the five
# kinds. In "## Step 9", each answer and its action must be in the same
# numbered item. The push protection step in the report must say that it
# is for a public repo. "## Step 6" must run the commands of item 1 after
# the approval, with no second ```sh block, and must give the visibility
# as a choice. Steps 5, 7, 8, 13, and 15 must keep the review rules: no `*`
# and no space at an end in a command value, no allow rule for a `&&` part
# with `*`, the temp files of exit 3, setup.md items 1 to 6, no push after
# a failed commit, and `rm .DS_Store` before `git add -A`.
#
# setup.md must check the plugins with `flow-plugins --status`, report six
# results, give the install and update commands, do the `jq -S` compare,
# and ask for approval before it runs a plugin command.
# docs/settings-template.md must name `flow-plugins --status`.
#
# The command count check: the commands folder must hold 17 commands,
# CLAUDE.md must say 17, and docs/command-conventions.md must name
# new-project.
#
# Each check also runs against a copy with one fact broken. The check must
# fail on that copy.
#
# The checks are phrase checks on the command text. They cannot check what
# a model does at run time.
#
# COMMANDS_DIR points the test at a copy of plugins/flow/commands.
#
# Usage: bash tests/commands/test-new-project.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# SC2016: the backticks in the patterns are Markdown text, not commands.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_DIR="${COMMANDS_DIR:-$REAL_REPO/plugins/flow/commands}"
FAMILIES_DOC="$REAL_REPO/docs/families.md"
CONVENTIONS_DOC="$REAL_REPO/docs/command-conventions.md"
CLAUDE_MD="$REAL_REPO/CLAUDE.md"
SETTINGS_DOC="$REAL_REPO/docs/settings-template.md"
FLOW_TEMPLATE="$REAL_REPO/plugins/flow/bin/flow-template"

FAMILY_ORDER='ios-app container-ghcr web-app static-site-cloudflare static-site-host other'

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

# family_order <file> <heading>
# Prints the family names of the numbered list in the section, in order,
# on one line. Each list item gives its family in backticks after a colon.
family_order() {
    section "$1" "$2" |
        sed -n 's/^[0-9][0-9]*\. [^:]*: `\([a-z-]*\)`.*/\1/p' |
        tr '\n' ' ' | sed 's/ $//'
}

# bad_order <file> <heading>
# Prints a line when the family order in the section is not FAMILY_ORDER.
bad_order() {
    local got
    got=$(family_order "$1" "$2")
    [ "$got" = "$FAMILY_ORDER" ] || echo "family order is '$got'"
}

# approved_before <file> <pattern>
# Prints a line when the first line in a ```sh fence that matches
# <pattern> has no "If the user approves" line before it in the same
# "## " section. A ```text fence only shows a command, so it does not count.
approved_before() {
    awk -v pat="$2" '
        /^## / { approved = 0 }
        /^[ \t]*```sh[ \t]*$/ && !fence { fence = 1; run = 1; next }
        /^[ \t]*```/ { if (fence) { fence = 0; run = 0 } else { fence = 1; run = 0 }; next }
        !fence && /If the user approves/ { approved = 1 }
        fence && run && $0 ~ pat {
            if (!approved) print "no approval before: " $0
            found = 1
            exit
        }
        END { if (!found) print "no sh line matches " pat }
    ' "$1"
}

# fenced_force <file>
# Prints each line in a code fence that uses --force.
fenced_force() {
    awk '
        /^[ \t]*(```|~~~)/ { fence = !fence; next }
        fence && /--force/ { print "uses --force: " $0 }
    ' "$1"
}

# bad_questions <file>
# Prints a line for each setup topic or kind that "## Step 2" does not
# name. A topic is the label at the start of a numbered item.
bad_questions() {
    local step2 topic kind
    step2=$(section "$1" '## Step 2: Ask the setup questions')
    for topic in 'Kind:' 'Container image:' 'Deploy target:' 'Visibility:' \
        'Outside contributors:' 'Database:' 'Secrets'; do
        printf '%s\n' "$step2" | grep -qE "^[0-9]+\. ${topic}" || echo "Step 2 does not ask $topic"
    done
    for kind in '`Static site`' '`Web app`' '`Container app`' '`iOS app`' '"other"' '`Private`' '`Public`'; do
        printf '%s\n' "$step2" | grep -qF -- "$kind" || echo "Step 2 does not name $kind"
    done
}

# item_with <file> <heading> <lead> <needle>
# Prints a line when the numbered item that starts with <lead> in the
# section does not hold <needle>. An item ends at the next item at column
# 0 or at the end of the section.
item_with() {
    section "$1" "$2" | awk -v lead="$3" -v needle="$4" '
        /^[0-9]+\. / { on = (index($0, lead) > 0); if (on) seen = 1 }
        on && index($0, needle) > 0 { found = 1 }
        END {
            if (!seen) print "no item starts with " lead
            else if (!found) print "the " lead " item does not hold " needle
        }
    '
}

# bad_step9 <file>
# Prints a line for each answer in "## Step 9" whose action is not in its
# numbered item.
bad_step9() {
    local h='## Step 9: Apply the setup answers'
    item_with "$1" "$h" 'Private repo:' '`required_checks`'
    item_with "$1" "$h" 'Outside contributors:' '`flow-template --pin <sha> <tag>`'
    item_with "$1" "$h" 'Secrets or a database' '`flow-template --env-hook`'
}

# bad_report <file>
# Prints a line when the push protection step of the report does not say
# that it is for a public repo.
bad_report() {
    section "$1" '## Step 16: Report' | grep -qE '^ *[0-9]+\. Public repo: .*push protection' ||
        echo "the push protection step does not say public repo"
}

# bad_step6 <file>
# Prints a line when "## Step 6" does not run the exact commands of item 1
# after the approval. git ignores -b when .git exists, so item 1 must name
# `git symbolic-ref`. A second ```sh block could drift from item 1, so the
# run item names item 1 and has no block. A command line in a fence must
# give the visibility as the choice <--private or --public>, not a fixed
# flag.
bad_step6() {
    section "$1" '## Step 6: Create the GitHub repo' | awk '
        /`git symbolic-ref HEAD refs\/heads\/main`|^ *git symbolic-ref HEAD refs\/heads\/main$/ { sym = 1 }
        /Ask for approval/ { asked = 1 }
        /If the user approves, run the commands from item 1, in that order\./ {
            run = 1
            if (!asked) print "runs before the approval"
        }
        /^[ \t]*```sh[ \t]*$/ { print "Step 6 has a ```sh run block" }
        /^[ \t]*```/ { fence = !fence; next }
        fence && /gh repo create/ {
            create = 1
            line = $0
            if (index(line, "<--private or --public>") > 0) choice = 1
            gsub(/<--private or --public>/, "", line)
            if (line ~ /--private|--public/) print "fixed visibility flag: " $0
        }
        END {
            if (!sym) print "Step 6 does not name git symbolic-ref"
            if (!run) print "the run item does not run the commands from item 1, in that order"
            if (!create) print "item 1 has no gh repo create command"
            else if (!choice) print "gh repo create has no <--private or --public> choice"
        }
    '
}

# flat <file> <heading>: the section on one line, with each run of spaces
# made one space. Text wraps at any word, so the checks match words.
flat() {
    section "$1" "$2" | tr -s ' \n' '  '
}

# bad_review_fixes <file>
# Prints a line for each rule from the review that new-project.md breaks:
# the * and space rule for command values (Step 5), the && split of an
# allow rule (Step 8, twice), the temp-file case of exit 3 (Step 7), the
# setup.md items (Step 13), and the commit failure and .DS_Store items
# (Step 15).
bad_review_fixes() {
    local t n
    t=$(flat "$1" '## Step 5: Ask the commands')
    [[ "$t" == *'`verify` value that has `*` at any position.'*'An allow rule with `*` lets Claude run other commands with no approval.'* ]] ||
        echo "Step 5 does not refuse * at any position, with the reason"
    [[ "$t" == *'`verify` value that starts or ends with a space or tab.'* ]] ||
        echo "Step 5 does not refuse a space at the start or end"
    t=$(flat "$1" '## Step 8: Make the family edits')
    n=$(printf '%s' "$t" | grep -oF 'Remove the spaces at the start and end of each part. Do not make a rule for a part that is empty or has `*`.' | wc -l | tr -d ' ')
    [ "$n" = 2 ] || echo "Step 8 gives the && part rule $n times (want 2: web-app and container-ghcr)"
    t=$(flat "$1" '## Step 7: Copy the template files')
    [[ "$t" == *'Exit 3: a partial write.'*'temp files (`.flow-template.*`) stay in the repo.'* ]] ||
        echo "Step 7 exit 3 does not name the temp files"
    t=$(flat "$1" '## Step 13: Install the enabled plugins')
    [[ "$t" == *'Do its items 1 to 6.'*'Do not do items 7 and 8 of that step.'*'has no commit yet.'*'`/reload-plugins`'* ]] ||
        echo "Step 13 does not cite setup.md items 1 to 6 and skip 7 and 8 with the reason"
    section "$1" '## Step 15: Commit and push' | awk '
        /`rm \.DS_Store`/ && !fence1 { ds = 1 }
        /Ask for approval/ && ds && !fence1 { dsask = 1 }
        /^[ \t]*```/ { fence1 = 1 }
        END { if (!dsask) print "Step 15 does not show rm .DS_Store for approval before git add -A" }
    '
    t=$(flat "$1" '## Step 15: Commit and push')
    [[ "$t" == *'Run `git push` only if `git commit` succeeds'*'If `git commit` fails for a cause that is not a pre-commit hook, show the output. Do not run `git push`.'*'Go to Step 16.'* ]] ||
        echo "Step 15 does not stop before the push when the commit fails"
}

# bad_start <file>
# Prints a line for each start or end rule that the command breaks: the
# --plugin-dir start line, .DS_Store in the empty folder, and the report
# of a failed push.
bad_start() {
    section "$1" '## Before you start' | grep -qF 'claude --plugin-dir ~/.claude/plugins/marketplaces/devkit/plugins/flow' ||
        echo "no --plugin-dir start line"
    section "$1" '## Step 1: Check the folder' | grep -qF '.DS_Store' ||
        echo "Step 1 does not accept .DS_Store"
    section "$1" '## Step 15: Commit and push' | grep -qF 'committed, not pushed' ||
        echo "Step 15 does not report a failed push"
}

# bad_new_project <file>
# Prints one line for each rule that new-project.md breaks.
bad_new_project() {
    local name
    bad_order "$1" '## Step 3: Recommend the family'
    approved_before "$1" 'git commit'
    approved_before "$1" 'git push'
    fenced_force "$1"
    section "$1" '## Hard constraints' | grep -qF 'Never use `--force`' ||
        echo "hard constraints do not forbid --force"
    for name in '`flow-template --apply' '--host' '`flow-template --pin <sha> <tag>`' \
        '`flow-template --env-hook`' '`flow-template --leftover`' \
        '`flow-claude-block --status`' '`flow-labels --create`' \
        '`flow-plugins --status`' '`pre-commit install`' '`required_checks`' \
        'Semgrep' 'GitGuardian' 'push protection' \
        'site / Build' 'image / Lint (Dockerfile)' 'semgrep-cloud-platform/scan'; do
        grep -qF -- "$name" "$1" || echo "does not name $name"
    done
    grep -q 'Step 0' "$1" && echo "has a Step 0"
    awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } /^model:/ { print "has a model: key" }' "$1"
}

# bad_setup <file>
# Prints one line for each rule that the plugin step of setup.md breaks.
bad_setup() {
    local name step7
    for name in '`flow-plugins --status`' 'six results' 'claude plugin install' \
        'claude plugin update' '--scope project' 'jq -S' \
        'git checkout -- .claude/settings.json' '/reload-plugins'; do
        grep -qF -- "$name" "$1" || echo "does not name $name"
    done
    grep -q 'five results' "$1" && echo "says five results"
    step7=$(section "$1" '## Step 7: Install or update the enabled plugins')
    if [ -z "$step7" ]; then
        echo "no Step 7"
        return
    fi
    printf '%s\n' "$step7" | awk '
        /Ask for approval/ { asked = 1 }
        /Run each approved command/ { ran = 1; if (!asked) print "runs before the approval" }
        END { if (!ran) print "Step 7 does not run the approved commands" }
    '
}

# bad_counts <commands-dir>
# Prints a line when the command count is not 17 in the folder and in
# CLAUDE.md, or when the conventions doc does not name new-project.
bad_counts() {
    local count
    count=$(find "$1" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
    [ "$count" = 17 ] || echo "the folder has $count commands"
    grep -qF 'The 17 `/flow:` commands' "$CLAUDE_MD" || echo "CLAUDE.md does not say 17 commands"
    grep -q 'new-project' "$CONVENTIONS_DOC" || echo "command-conventions.md does not name new-project"
}

# check <label> <output>
# Passes when <output> is empty.
check() {
    if [ -z "$2" ]; then
        pass "$1"
    else
        fail "$1" "$2"
    fi
}

# expect_fail <label> <output>
# Passes when <output> is not empty: the check found the broken fact.
expect_fail() {
    if [ -n "$2" ]; then
        pass "$1"
    else
        fail "$1"
    fi
}

NEW="$COMMANDS_DIR/new-project.md"
SETUP="$COMMANDS_DIR/setup.md"

# --- The real files ---

check "new-project.md follows its rules" "$(bad_new_project "$NEW")"
check "new-project.md Step 6 runs the commands of item 1" "$(bad_step6 "$NEW")"
check "new-project.md has the review rules (Steps 5, 7, 8, 13, 15)" "$(bad_review_fixes "$NEW")"
check "new-project.md has the start line, accepts .DS_Store, and reports a failed push" "$(bad_start "$NEW")"
if grep -qF 'claude --plugin-dir ~/.claude/plugins/marketplaces/devkit/plugins/flow' "$REAL_REPO/README.md"; then
    pass "README.md gives the --plugin-dir start line for /flow:new-project"
else
    fail "README.md gives the --plugin-dir start line for /flow:new-project"
fi
check "new-project.md Step 2 names the seven setup topics and the kinds" "$(bad_questions "$NEW")"
check "new-project.md Step 9 keeps each answer with its action" "$(bad_step9 "$NEW")"
check "new-project.md says push protection is for a public repo" "$(bad_report "$NEW")"
if grep -qF '`flow-plugins --status`' "$SETTINGS_DOC"; then
    pass "docs/settings-template.md names flow-plugins --status"
else
    fail "docs/settings-template.md names flow-plugins --status"
fi
check "docs/families.md gives the same family order" \
    "$(bad_order "$FAMILIES_DOC" '## Choose a family')"
got=$("$FLOW_TEMPLATE" --list | tr '\n' ' ' | sed 's/ $//')
if [ "$got" = "$FAMILY_ORDER" ]; then
    pass "flow-template --list gives the same family order"
else
    fail "flow-template --list gives the same family order" "got '$got'"
fi
check "setup.md has the plugin step" "$(bad_setup "$SETUP")"
check "the command count is 17 and the docs agree" "$(bad_counts "$COMMANDS_DIR")"

# --- Fixtures: each check can fail ---

# harness.sh removes $TMPROOT on exit.
TMPROOT=$(mktemp -d)

# broken <name> <file> <sed-script>
# Writes a copy of <file> edited with <sed-script>. Prints its path.
broken() {
    sed "$3" "$2" > "$TMPROOT/$1"
    echo "$TMPROOT/$1"
}

f=$(broken swap.md "$NEW" 's/^2\. A container image: `container-ghcr`\./2. A container image: `web-app`./')
expect_fail "new-project.md with a swapped family order fails" "$(bad_order "$f" '## Step 3: Recommend the family')"

f=$(broken swap-doc.md "$FAMILIES_DOC" 's/^1\. An iOS app: `ios-app`\./1. An iOS app: `other`./')
expect_fail "families.md with a swapped family order fails" "$(bad_order "$f" '## Choose a family')"

f=$(broken repo.md "$NEW" '/^## Step 6/,/^## Step 7/{/If the user approves/d;}')
expect_fail "new-project.md with no approval before gh repo create fails" "$(bad_step6 "$f")"

f=$(broken repo-ask.md "$NEW" '/^## Step 6/,/^## Step 7/{/Ask for approval/d;}')
expect_fail "new-project.md that runs gh repo create before the approval fails" "$(bad_step6 "$f")"

f=$(broken private.md "$NEW" '/^## Step 6/,/^## Step 7/{s/<--private or --public>/--private/;}')
expect_fail "new-project.md with a fixed --private in Step 6 fails" "$(bad_step6 "$f")"

f=$(broken run-block.md "$NEW" '/^## Step 6/,/^## Step 7/{s/^   Use the exact commands that item 2 showed\.$/   ```sh\
   gh repo create <name> <--private or --public> --source .\
   ```/;}')
expect_fail "new-project.md with a second sh block in Step 6 fails" "$(bad_step6 "$f")"

f=$(broken star.md "$NEW" 's/has `\*` at any position\./is `*`./')
expect_fail "new-project.md Step 5 with only the exact * rule fails" "$(bad_review_fixes "$f")"

f=$(broken space.md "$NEW" 's/starts or ends with a space or tab\./is empty./')
expect_fail "new-project.md Step 5 with no space rule fails" "$(bad_review_fixes "$f")"

f=$(broken split.md "$NEW" '/^## Step 8/,/^## Step 9/{/^   and `lint`\. Use the rule form/,/^   is empty or has/{s/Remove the spaces/Keep the spaces/;};}')
expect_fail "new-project.md with the && part rule only for web-app fails" "$(bad_review_fixes "$f")"

f=$(broken exit3.md "$NEW" 's/files (`\.flow-template\.\*`) stay/files stay/')
expect_fail "new-project.md Step 7 exit 3 with no temp-file case fails" "$(bad_review_fixes "$f")"

f=$(broken items.md "$NEW" 's/Do its items 1 to 6\./Do its items 1 to 5./')
expect_fail "new-project.md Step 13 with items 1 to 5 fails" "$(bad_review_fixes "$f")"

f=$(broken dsstore.md "$NEW" '/^## Step 15/,/^## Step 16/{/^2\. Do this item only if `\.DS_Store`/,/^   `rm \.DS_Store`/d;}')
expect_fail "new-project.md Step 15 with no rm .DS_Store item fails" "$(bad_review_fixes "$f")"

f=$(broken commitfail.md "$NEW" 's/^   the output\. Do not run `git push`\. Record the result as "not$/   the output. Record the result as "not/')
expect_fail "new-project.md Step 15 that pushes after a failed commit fails" "$(bad_review_fixes "$f")"

f=$(broken commit.md "$NEW" '/^## Step 15/,/^## Step 16/{/If the user approves/d;}')
expect_fail "new-project.md with no approval before git commit fails" "$(approved_before "$f" 'git commit')"
expect_fail "new-project.md with no approval before git push fails" "$(approved_before "$f" 'git push')"

f=$(broken force.md "$NEW" 's/^   git push -u origin main$/   git push --force -u origin main/')
expect_fail "new-project.md that pushes with --force fails" "$(fenced_force "$f")"

f=$(broken pin.md "$NEW" 's/flow-template --pin/flow-template --pinned/g')
expect_fail "new-project.md with no --pin fails" "$(bad_new_project "$f")"

f=$(broken step0.md "$NEW" 's/^## Step 1: Check the folder$/## Step 0: Project facts/')
expect_fail "new-project.md with a Step 0 fails" "$(bad_new_project "$f")"

f=$(broken model.md "$NEW" '2i\
model: sonnet
')
expect_fail "new-project.md with a model: key fails" "$(bad_new_project "$f")"

f=$(broken push-protection.md "$NEW" 's/push protection/the scan/g')
expect_fail "new-project.md with no push protection step fails" "$(bad_new_project "$f")"

f=$(broken step6.md "$NEW" 's/^   git symbolic-ref HEAD refs\/heads\/main$/   git init -b main/')
expect_fail "new-project.md that always runs git init -b main fails" "$(bad_step6 "$f")"

f=$(broken no-start.md "$NEW" 's#~/.claude/plugins/marketplaces/devkit/plugins/flow#plugins/flow#')
expect_fail "new-project.md with no --plugin-dir start line fails" "$(bad_start "$f")"

f=$(broken no-dsstore.md "$NEW" '/^## Step 1/,/^## Step 2/{s/\.DS_Store/.junk/g;}')
expect_fail "new-project.md that does not accept .DS_Store fails" "$(bad_start "$f")"

f=$(broken no-push.md "$NEW" 's/committed, not pushed/done/g')
expect_fail "new-project.md with no failed push report fails" "$(bad_start "$f")"

f=$(broken no-db.md "$NEW" '/^## Step 2/,/^## Step 3/{/^6\. Database:/d;}')
expect_fail "new-project.md with no database question fails" "$(bad_questions "$f")"

f=$(broken no-ios.md "$NEW" '/^## Step 2/,/^## Step 3/{s/`iOS app`/`Mobile app`/;}')
expect_fail "new-project.md with no iOS kind fails" "$(bad_questions "$f")"

f=$(broken step9-swap.md "$NEW" '/^## Step 9/,/^## Step 10/{s/^1\. Private repo:/1. Secrets or a database:/;s/^3\. Secrets or a database/3. Private repo:/;}')
expect_fail "new-project.md with Step 9 actions in the wrong items fails" "$(bad_step9 "$f")"

f=$(broken pin-moved.md "$NEW" '/^## Step 9/,/^## Step 10/{s/^2\. Outside contributors:/2. Contributors:/;}')
expect_fail "new-project.md with no outside contributors item fails" "$(bad_step9 "$f")"

f=$(broken public.md "$NEW" 's/Public repo: turn on secret scanning/Turn on secret scanning/')
expect_fail "new-project.md with push protection not for a public repo fails" "$(bad_report "$f")"

sed 's/`flow-plugins --status`/`flow-plugins`/g' "$SETTINGS_DOC" > "$TMPROOT/settings-doc.md"
if grep -qF '`flow-plugins --status`' "$TMPROOT/settings-doc.md"; then
    fail "control: a settings doc with no flow-plugins --status fails the check"
else
    pass "control: a settings doc with no flow-plugins --status fails the check"
fi

f=$(broken five.md "$SETUP" 's/six results/five results/')
expect_fail "setup.md that says five results fails" "$(bad_setup "$f")"

f=$(broken setup-approval.md "$SETUP" '/^## Step 7/,/^## Step 8/{/Ask for approval/d;}')
expect_fail "setup.md with no approval before the plugin run fails" "$(bad_setup "$f")"

f=$(broken setup-jq.md "$SETUP" 's/jq -S/jq/g')
expect_fail "setup.md with no jq -S compare fails" "$(bad_setup "$f")"

mkdir -p "$TMPROOT/extra"
cp "$COMMANDS_DIR"/*.md "$TMPROOT/extra/"
touch "$TMPROOT/extra/extra.md"
expect_fail "a folder with 18 commands fails" "$(bad_counts "$TMPROOT/extra")"

harness_report
