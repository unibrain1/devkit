#!/bin/bash
#
# Tests for .github/scripts/upstream-sync.sh. A fake `gh` goes first on PATH.
# It answers from fixture JSON and runs the real jq filter, so a wrong --jq
# filter in the script fails the test.
#
# Usage: bash tests/scripts/test-upstream-sync.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/.github/scripts/upstream-sync.sh"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1
STUBDIR="$TMPROOT/bin"
mkdir -p "$STUBDIR"

OLD=8da6b6340aa22faf46fd07db8efbdea010cd38d9
NEW=1234567890abcdef1234567890abcdef12345678

# Fake gh: `gh api <endpoint> --jq <filter>`.
#   FAKE_HEAD     The SHA that the commits endpoint reports.
#   FAKE_FAIL=1   Every call exits 1.
cat > "$STUBDIR/gh" <<'STUB'
#!/bin/bash
[ "${FAKE_FAIL:-0}" = "1" ] && { echo "gh: simulated failure" >&2; exit 1; }
[ "$1" = "api" ] || { echo "fake gh: unexpected call: $*" >&2; exit 2; }
endpoint="$2"
filter="."
[ "${3:-}" = "--jq" ] && filter="$4"
case "$endpoint" in
    repos/*/commits/*) json="{\"sha\": \"${FAKE_HEAD}\"}" ;;
    repos/*/*) json='{"default_branch": "main"}' ;;
    *) echo "fake gh: unexpected endpoint: $endpoint" >&2; exit 2 ;;
esac
printf '%s' "$json" | jq -r "$filter"
STUB
chmod +x "$STUBDIR/gh"

# fixtures <dir>: writes a marketplace with one local and one pinned plugin,
# and a sources.md with the pin row and one unrelated row.
fixtures() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/marketplace.json" <<EOF
{
  "name": "devkit",
  "plugins": [
    {
      "name": "flow",
      "source": "./plugins/flow"
    },
    {
      "name": "asd-ste100",
      "source": {
        "source": "github",
        "repo": "danyuchn/asd-ste100-skill",
        "sha": "$OLD"
      }
    }
  ]
}
EOF
    cat > "$dir/sources.md" <<EOF
| Item | Source |
| --- | --- |
| \`asd-ste100\` | at [\`8da6b63\`](https://github.com/danyuchn/asd-ste100-skill/commit/$OLD) (2026-10-26). |
| Other | Recorded (2026-10-26). |
EOF
}

run() {
    PATH="$STUBDIR:$PATH" UPSTREAM_SYNC_DATE=2026-11-02 "$SCRIPT" "$1/marketplace.json" "$1/sources.md" 2>/dev/null
}

# 1. Current pin: no output, no change.
d="$TMPROOT/current"; fixtures "$d"; cp -R "$d" "$d.orig"
out="$(FAKE_HEAD=$OLD run "$d")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && diff -r "$d" "$d.orig" >/dev/null; then
    pass "current pin: no output, files unchanged"
else
    fail "current pin" "exit: $rc" "stdout: [$out]"
fi

# 2. Moved pin: one output line, both files updated, other rows unchanged.
d="$TMPROOT/moved"; fixtures "$d"
out="$(FAKE_HEAD=$NEW run "$d")"; rc=$?
want="$(printf 'asd-ste100\tdanyuchn/asd-ste100-skill\t%s\t%s' "$OLD" "$NEW")"
if [ "$rc" -eq 0 ] && [ "$out" = "$want" ]; then
    pass "moved pin: output line"
else
    fail "moved pin: output line" "exit: $rc" "stdout: [$out]" "want:   [$want]"
fi
if [ "$(jq -r '.plugins[1].source.sha' "$d/marketplace.json")" = "$NEW" ] \
    && [ "$(jq -r '.plugins[0].source' "$d/marketplace.json")" = "./plugins/flow" ]; then
    pass "moved pin: marketplace SHA updated, local plugin kept"
else
    fail "moved pin: marketplace" "$(cat "$d/marketplace.json")"
fi
row="$(grep asd-ste100 "$d/sources.md")"
case "$row" in
    *"\`1234567\`"*"commit/$NEW) (2026-11-02)."*) pass "moved pin: sources row has new SHA, short SHA, and date" ;;
    *) fail "moved pin: sources row" "$row" ;;
esac
if grep -qF "| Other | Recorded (2026-10-26). |" "$d/sources.md" && ! grep -q "$OLD" "$d/sources.md"; then
    pass "moved pin: other rows unchanged, old SHA gone"
else
    fail "moved pin: other rows" "$(cat "$d/sources.md")"
fi

# 3. gh fails: exit 1, no change.
d="$TMPROOT/ghfail"; fixtures "$d"; cp -R "$d" "$d.orig"
FAKE_FAIL=1 FAKE_HEAD=$NEW run "$d" >/dev/null; rc=$?
if [ "$rc" -eq 1 ] && diff -r "$d" "$d.orig" >/dev/null; then
    pass "gh failure: exit 1, files unchanged"
else
    fail "gh failure" "exit: $rc (want 1)"
fi

# 4. Upstream answer is not a SHA: exit 1, no change.
d="$TMPROOT/badsha"; fixtures "$d"; cp -R "$d" "$d.orig"
FAKE_HEAD=null run "$d" >/dev/null; rc=$?
if [ "$rc" -eq 1 ] && diff -r "$d" "$d.orig" >/dev/null; then
    pass "bad SHA: exit 1, files unchanged"
else
    fail "bad SHA" "exit: $rc (want 1)"
fi

# 5. No pinned plugin: exit 0, no output.
d="$TMPROOT/nopin"; mkdir -p "$d"
printf '{"plugins": [{"name": "flow", "source": "./plugins/flow"}]}\n' > "$d/marketplace.json"
: > "$d/sources.md"
out="$(FAKE_HEAD=$NEW run "$d")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "no pinned plugin: exit 0, no output"
else
    fail "no pinned plugin" "exit: $rc" "stdout: [$out]"
fi

# 6. Missing file: exit 1.
PATH="$STUBDIR:$PATH" FAKE_HEAD=$NEW "$SCRIPT" "$TMPROOT/none.json" "$TMPROOT/none.md" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then pass "missing file: exit 1"; else fail "missing file" "exit: $rc (want 1)"; fi

harness_report
