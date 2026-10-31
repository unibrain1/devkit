#!/bin/bash
#
# Tests that /flow:plan-milestone and /flow:start-milestone check the
# version with flow-check-version-newer before they change GitHub or git.
# A bad version must stop the command before it creates a milestone, edits
# an issue, or makes a branch.
#
# The test reads only the fenced code blocks of the commands. A write
# command in prose is not a command that the model runs. A line that ends
# in "\" joins the next line, so a flag on a continuation line counts.
#
# The test also checks that the "## Step 0b: Check the version" section
# names the expected form for exit 2 and the last tag for exit 1, that the
# exit 1 bullet says to stop, and that the exit 2 text has a stop
# instruction. It also checks that the call quotes "$ARGUMENTS".
#
# COMMANDS_DIR points the test at a copy of plugins/flow/commands.
#
# Usage: bash tests/commands/test-version-check-at-start.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# shellcheck disable=SC2016 # the backticks are Markdown text, not commands
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_DIR="${COMMANDS_DIR:-$REAL_REPO/plugins/flow/commands}"

# first_lines <file>
# Prints "<check-line> <write-line>". <check-line> is the first line of the
# first flow-check-version-newer command in a fenced code block (``` or
# ~~~). <write-line> is the first line of the first command that changes
# GitHub or git. A value is 0 when the file has no such command.
first_lines() {
    awk '
        /^[ \t]*(```|~~~)/ { in_code = !in_code; cmd = ""; next }
        !in_code { next }
        {
            line = $0
            if (cmd == "") start = NR
            # Read the trailing "\" before the comment strip. A "#" in a
            # quoted value would otherwise remove it.
            cont = sub(/\\[ \t]*$/, "", line)
            # A check in a shell comment does not run.
            sub(/(^|[ \t])#.*/, "", line)
            if (cont) { cmd = cmd line " "; next }
            cmd = cmd line
            if (!check && cmd ~ /flow-check-version-newer/) check = start
            if (!write && (cmd ~ /gh api/ && cmd ~ /(^|[ \t])(-f|-F|--field|--raw-field|-X|--method|--input)[ \t]/ ||
                           cmd ~ /gh issue (create|edit|comment|close)/ || cmd ~ /gh (label|pr|release)/ ||
                           cmd ~ /git (checkout|switch|branch|tag|commit|push|pull)/))
                write = start
            cmd = ""
        }
        END { print check + 0, write + 0 }
    ' "$1"
}

# bad_order <file>
# Prints one line when <file> has no check, or when a write command comes
# before the check. Prints nothing when the order is correct. When awk
# prints no numbers, the test cannot tell the order, so that fails too.
bad_order() {
    local check write
    read -r check write <<EOF
$(first_lines "$1")
EOF
    case "$check" in ''|*[!0-9]*) echo "cannot read the line numbers: [$check] [$write]"; return ;; esac
    case "$write" in ''|*[!0-9]*) echo "cannot read the line numbers: [$check] [$write]"; return ;; esac
    if [ "$check" -eq 0 ]; then
        echo "no flow-check-version-newer in a code block"
    elif [ "$write" -ne 0 ] && [ "$write" -lt "$check" ]; then
        echo "write command at line $write comes before the check at line $check"
    fi
}

# bad_step_text <file>
# Prints one line for each rule that the "## Step 0b: Check the version"
# section of <file> breaks, or one line when the section is absent.
bad_step_text() {
    awk '
        /^## / { in_section = ($0 == "## Step 0b: Check the version"); if (in_section) found = 1; next }
        !in_section { next }
        # Each top-level bullet ends the text of the bullet before it, so a
        # later "Any other exit code" line is not part of the exit 2 text.
        /^- / { where = 0 }
        /^- \*\*Exit 1\*\*/ { where = 1 }
        /^- \*\*Exit 2\*\*/ { where = 2 }
        /^- \*\*Exit 1\*\* — stop/ { stop1 = 1 }
        where == 1 { exit1 = exit1 $0 "\n" }
        where == 2 { exit2 = exit2 $0 "\n" }
        # The stop for a bad form is the main rule of the check. Other
        # sub-items also say "stop", so the exit 2 bullet as a whole cannot
        # prove it. Read the one sub-item line for the parse error.
        where == 2 && /^[ \t]+[0-9]+\. `Could not parse candidate version`/ { cand = $0 }
        END {
            if (!found) { print "no \"## Step 0b: Check the version\" section"; exit }
            if (exit1 !~ /last tag/) print "the exit 1 text does not name the last tag"
            if (!stop1) print "the exit 1 text does not say stop"
            if (exit2 !~ /— stop/) print "the exit 2 text does not say stop"
            if (cand == "") print "the exit 2 text has no sub-item for Could not parse candidate version"
            else if (cand !~ /— stop/) print "the Could not parse candidate version sub-item does not say stop"
            if (exit2 !~ /vX\.Y\.Z`? or `?vX\.Y\.Z\.N/) print "the exit 2 text does not name vX.Y.Z or vX.Y.Z.N"
        }
    ' "$1"
}

for f in plan-milestone.md start-milestone.md; do
    path="$COMMANDS_DIR/$f"
    if [ ! -r "$path" ]; then
        fail "$f: the test can read the command file" "$path"
        continue
    fi
    bad="$(bad_order "$path")"
    if [ -z "$bad" ]; then
        pass "$f: the version check comes before the first write command"
    else
        fail "$f: the version check comes before the first write command" "$bad"
    fi
    bad="$(bad_step_text "$path")"
    if [ -z "$bad" ]; then
        pass "$f: Step 0b names the form for exit 2 and the last tag for exit 1"
    else
        fail "$f: Step 0b names the form for exit 2 and the last tag for exit 1" "$bad"
    fi
    # Without the quotes, an extra word in $ARGUMENTS becomes the last tag.
    if grep -qF 'flow-check-version-newer "$ARGUMENTS"' "$path" \
        && ! grep -qF 'flow-check-version-newer $ARGUMENTS' "$path"; then
        pass "$f: the check quotes \"\$ARGUMENTS\""
    else
        fail "$f: the check quotes \"\$ARGUMENTS\"" "$(grep -n 'flow-check-version-newer' "$path")"
    fi
done

TMPROOT="$(mktemp -d)"

# fixture <name> <text>
# Writes $TMPROOT/<name>.md with <text>.
fixture() {
    printf '%s\n' "$2" > "$TMPROOT/$1.md"
}

# Each write command before the check must fail the order check.
n=0
for write in 'gh api "repos/$REPO/milestones" -f title="v1"' \
             'gh api "repos/$REPO/milestones/1" -X PATCH -f state=closed' \
             'gh issue edit 1 --milestone v1' \
             'gh issue comment 1 --body "x"' \
             'gh label create x' \
             'git checkout -b milestone/v1' \
             'git commit -m x' \
             'git push origin milestone/v1' \
             'gh issue close 1 --reason "not planned"' \
             'gh issue create --title x' \
             'gh pr create --base main' \
             'git switch -c milestone/v1' \
             'git tag v1'; do
    n=$((n + 1))
    fixture "write-$n" "# Fixture

\`\`\`bash
$write
\`\`\`

\`\`\`bash
flow-check-version-newer \$ARGUMENTS
\`\`\`"
    if bad_order "$TMPROOT/write-$n.md" | grep -q 'comes before the check'; then
        pass "a write before the check fails: $write"
    else
        fail "a write before the check fails: $write"
    fi
done

# A write flag on a continuation line counts.
fixture continuation '# Fixture

```bash
gh api "repos/$REPO/milestones" \
  -f title="v1"
```

```bash
flow-check-version-newer $ARGUMENTS
```'
if bad_order "$TMPROOT/continuation.md" | grep -q 'comes before the check'; then
    pass "a write flag on a continuation line counts"
else
    fail "a write flag on a continuation line counts"
fi

# A "#" in a quoted value does not hide the trailing "\".
fixture hash-continuation '# Fixture

```bash
gh api "repos/$REPO/milestones" -H "X-Note: see #1" \
  -f title="v1"
```

```bash
flow-check-version-newer "$ARGUMENTS"
```'
if bad_order "$TMPROOT/hash-continuation.md" | grep -q 'comes before the check'; then
    pass "a # in a quoted value keeps the continuation"
else
    fail "a # in a quoted value keeps the continuation"
fi

# A read-only gh api call before the check does not fail the order check.
fixture read-only '# Fixture

```bash
gh api "repos/$REPO/milestones?state=open" --paginate --jq ".[].title"
flow-check-version-newer $ARGUMENTS
git push origin milestone/v1
```'
bad="$(bad_order "$TMPROOT/read-only.md")"
if [ -z "$bad" ]; then
    pass "a read-only gh api call before the check passes"
else
    fail "a read-only gh api call before the check passes" "$bad"
fi

# A check in prose only is not a command.
fixture prose '# Fixture

Run `flow-check-version-newer` first.

```bash
git push origin milestone/v1
```'
if bad_order "$TMPROOT/prose.md" | grep -q 'no flow-check-version-newer'; then
    pass "a check in prose only fails"
else
    fail "a check in prose only fails"
fi

# A check in a shell comment is not a command.
fixture commented '# Fixture

```bash
# flow-check-version-newer runs later
git push origin milestone/v1
flow-check-version-newer "$ARGUMENTS"
```'
if bad_order "$TMPROOT/commented.md" | grep -q 'comes before the check'; then
    pass "a check in a shell comment does not count"
else
    fail "a check in a shell comment does not count"
fi

# A Step 0b with no form or no last tag fails the text check.
fixture no-step '# Fixture'
if bad_step_text "$TMPROOT/no-step.md" | grep -q 'no "## Step 0b'; then
    pass "a command with no Step 0b fails the text check"
else
    fail "a command with no Step 0b fails the text check"
fi
fixture weak-step '# Fixture

## Step 0b: Check the version

- **Exit 1** — stop.
- **Exit 2** — stop. Use a version.'
bad="$(bad_step_text "$TMPROOT/weak-step.md")"
if printf '%s' "$bad" | grep -q 'last tag' && printf '%s' "$bad" | grep -q 'vX.Y.Z or vX.Y.Z.N'; then
    pass "a Step 0b with no form and no last tag fails the text check"
else
    fail "a Step 0b with no form and no last tag fails the text check" "$bad"
fi

# A Step 0b that continues on exit 1 or exit 2 fails the text check. The
# "Any other exit code" line says stop, and it must not count for exit 2.
fixture go-on-step '# Fixture

## Step 0b: Check the version

- **Exit 1** — continue. Name the last tag.
- **Exit 2** — continue. Use `vX.Y.Z` or `vX.Y.Z.N`.
- **Any other exit code** — stop.'
bad="$(bad_step_text "$TMPROOT/go-on-step.md")"
if printf '%s' "$bad" | grep -q 'exit 1 text does not say stop' && printf '%s' "$bad" | grep -q 'exit 2 text does not say stop'; then
    pass "a Step 0b that does not stop fails the text check"
else
    fail "a Step 0b that does not stop fails the text check" "$bad"
fi

# "do not stop" is not a stop.
fixture not-stop-step '# Fixture

## Step 0b: Check the version

- **Exit 1** — do not stop. Name the last tag.
- **Exit 2** — stop. Use `vX.Y.Z` or `vX.Y.Z.N`.'
if bad_step_text "$TMPROOT/not-stop-step.md" | grep -q 'exit 1 text does not say stop'; then
    pass "an exit 1 text with \"do not stop\" fails the text check"
else
    fail "an exit 1 text with \"do not stop\" fails the text check"
fi

# Only the "Could not parse candidate version" sub-item says "continue". The
# other sub-items say "stop", so a check on the whole exit 2 bullet passes.
# The check must still fail, because a bad form must stop the command.
fixture cand-continue-step '# Fixture

## Step 0b: Check the version

- **Exit 1** — stop. Name the last tag.
- **Exit 2** — read stderr:
  1. `Could not parse candidate version` — continue with the next step.
     Use `vX.Y.Z` or `vX.Y.Z.N`.
  2. `git describe --tags --abbrev=0 failed` — stop and show the stderr.
  3. Any other stderr — stop.'
bad="$(bad_step_text "$TMPROOT/cand-continue-step.md")"
if printf '%s' "$bad" | grep -q 'candidate version sub-item does not say stop' \
    && ! printf '%s' "$bad" | grep -q 'exit 2 text does not say stop'; then
    pass "a candidate version sub-item that continues fails the text check"
else
    fail "a candidate version sub-item that continues fails the text check" "$bad"
fi

# The same Step 0b with "stop" in the candidate version sub-item passes.
fixture cand-stop-step '# Fixture

## Step 0b: Check the version

- **Exit 1** — stop. Name the last tag.
- **Exit 2** — read stderr:
  1. `Could not parse candidate version` — stop. Use `vX.Y.Z` or `vX.Y.Z.N`.
  2. `git describe --tags --abbrev=0 failed` — continue.'
bad="$(bad_step_text "$TMPROOT/cand-stop-step.md")"
if [ -z "$bad" ]; then
    pass "a candidate version sub-item that stops passes the text check"
else
    fail "a candidate version sub-item that stops passes the text check" "$bad"
fi

harness_report
