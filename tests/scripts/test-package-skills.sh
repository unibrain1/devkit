#!/bin/bash
#
# Tests for .github/scripts/package-skills.sh. Each scenario makes a skills
# folder in a temp dir, runs the script, and checks the exit code and zips.
#
# Usage: bash tests/scripts/test-package-skills.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/.github/scripts/package-skills.sh"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1

# skill <skills-dir> <name> <frontmatter-name> <description>
skill() {
    mkdir -p "$1/$2"
    printf -- '---\nname: %s\ndescription: %s\n---\n\n# Body with <placeholder>\n' "$3" "$4" > "$1/$2/SKILL.md"
}

# 1. Good skill: exit 0, zip holds the folder and SKILL.md.
d="$TMPROOT/good"
skill "$d/skills" vault vault "Rules for the vault. Use when Jim says \"wrap\"."
out="$("$SCRIPT" "$d/skills" "$d/dist" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && unzip -l "$d/dist/vault.zip" | grep -q 'vault/SKILL.md'; then
    pass "good skill: exit 0, zip has vault/SKILL.md"
else
    fail "good skill" "exit: $rc" "output: [$out]"
fi

# 2. --check writes no zip.
d="$TMPROOT/check"
skill "$d/skills" vault vault "Rules for the vault."
"$SCRIPT" --check "$d/skills" "$d/dist" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$d/dist" ]; then
    pass "--check: exit 0, no dist"
else
    fail "--check" "exit: $rc"
fi

# 3. Angle brackets in the description: exit 1, no zip. Brackets in the body pass.
d="$TMPROOT/xml"
skill "$d/skills" vault vault "Use when Jim says \"pick up <activity>\"."
out="$("$SCRIPT" "$d/skills" "$d/dist" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ ! -e "$d/dist/vault.zip" ] && printf '%s' "$out" | grep -q "XML tags"; then
    pass "angle brackets in description: exit 1, no zip"
else
    fail "angle brackets" "exit: $rc" "output: [$out]"
fi

# 4. Name does not match the folder: exit 1.
d="$TMPROOT/name"
skill "$d/skills" vault other "Rules."
"$SCRIPT" --check "$d/skills" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then pass "name mismatch: exit 1"; else fail "name mismatch" "exit: $rc (want 1)"; fi

# 5. Description over 1024 characters: exit 1.
d="$TMPROOT/long"
skill "$d/skills" vault vault "$(printf 'a%.0s' $(seq 1 1025))"
"$SCRIPT" --check "$d/skills" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then pass "long description: exit 1"; else fail "long description" "exit: $rc (want 1)"; fi

# 6. No SKILL.md: exit 1.
d="$TMPROOT/nofile"
mkdir -p "$d/skills/vault"
"$SCRIPT" --check "$d/skills" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then pass "no SKILL.md: exit 1"; else fail "no SKILL.md" "exit: $rc (want 1)"; fi

# 7. Missing or empty skills dir: exit 2.
"$SCRIPT" --check "$TMPROOT/none" >/dev/null 2>&1; rc=$?
mkdir -p "$TMPROOT/empty"
"$SCRIPT" --check "$TMPROOT/empty" >/dev/null 2>&1; rc2=$?
if [ "$rc" -eq 2 ] && [ "$rc2" -eq 2 ]; then
    pass "missing or empty dir: exit 2"
else
    fail "missing or empty dir" "missing: $rc, empty: $rc2 (want 2, 2)"
fi

# 8. The real brain skills pass.
if (cd "$REAL_REPO" && "$SCRIPT" --check) >/dev/null 2>&1; then
    pass "real plugins/brain/skills pass"
else
    fail "real plugins/brain/skills" "$(cd "$REAL_REPO" && "$SCRIPT" --check 2>&1)"
fi

harness_report
