#!/bin/bash
#
# Tests for .github/scripts/check-action-pins.sh. Each scenario writes a
# fixture workflow folder under $TMPROOT and runs the real script on it.
#
# Usage: bash tests/scripts/test-check-action-pins.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/.github/scripts/check-action-pins.sh"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1

SHA=8da6b6340aa22faf46fd07db8efbdea010cd38d9
DEVKIT=unibrain1/devkit/.github/workflows/claude.yml
N=0

# pin_case <label> <want-rc> <uses-value>
# Writes a workflow with the uses value on line 5 and runs the script. When
# the script must fail, stderr must name file and line 5.
pin_case() {
    local label="$1" want="$2" ref="$3" dir err rc
    N=$((N + 1))
    dir="$TMPROOT/case$N"
    mkdir -p "$dir"
    printf 'name: t\non: push\njobs:\n  a:\n    uses: %s\n' "$ref" > "$dir/w.yml"
    err="$("$SCRIPT" "$dir" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -ne "$want" ]; then
        fail "$label: '$ref'" "exit: $rc, want $want" "stderr: [$err]"
        return
    fi
    if [ "$want" -eq 1 ] && [ "$err" != "$dir/w.yml:5: '$ref' is not pinned to a full commit SHA." ]; then
        fail "$label: '$ref' stderr" "stderr: [$err]"
        return
    fi
    if [ "$want" -eq 0 ] && [ -n "$err" ]; then
        fail "$label: '$ref' stderr not empty" "stderr: [$err]"
        return
    fi
    pass "$label: '$ref' exits $want"
}

# 1. Third-party actions need a lowercase 40-hex SHA.
pin_case "third-party SHA" 0 "actions/checkout@$SHA"
pin_case "third-party tag" 1 "actions/checkout@v4"
pin_case "third-party branch" 1 "actions/checkout@main"
pin_case "third-party 39-hex" 1 "actions/checkout@${SHA%?}"
pin_case "third-party 41-hex" 1 "actions/checkout@${SHA}a"
pin_case "third-party uppercase hex" 1 "actions/checkout@$(printf '%s' "$SHA" | tr 'a-f' 'A-F')"

# 2. A devkit reusable workflow passes at @main or a full @vX.Y.Z tag.
pin_case "devkit main" 0 "$DEVKIT@main"
pin_case "devkit full tag" 0 "$DEVKIT@v1.4.0"
pin_case "devkit .yaml" 0 "unibrain1/devkit/.github/workflows/claude.yaml@main"
pin_case "devkit SHA" 0 "$DEVKIT@$SHA"
pin_case "devkit short tag" 1 "$DEVKIT@v1.4"
pin_case "devkit major tag" 1 "$DEVKIT@v1"
pin_case "devkit tag suffix" 1 "$DEVKIT@v1.4.0-rc1"
pin_case "devkit other branch" 1 "$DEVKIT@feature"
pin_case "devkit master" 1 "$DEVKIT@master"
pin_case "devkit no ref" 1 "$DEVKIT"

# 3. Look-alikes of a devkit ref fail.
pin_case "devkit action path" 1 "unibrain1/devkit/.github/actions/x@main"
pin_case "devkit repo root" 1 "unibrain1/devkit@main"
pin_case "devkit workflow subfolder" 1 "unibrain1/devkit/.github/workflows/sub/claude.yml@main"
pin_case "look-alike repo" 1 "unibrain1/devkit-sandbox/.github/workflows/claude.yml@main"
pin_case "look-alike owner" 1 "unibrain11/devkit/.github/workflows/claude.yml@main"
pin_case "prefixed owner" 1 "evil/unibrain1/devkit/.github/workflows/claude.yml@main"
pin_case "not a yml file" 1 "unibrain1/devkit/.github/workflows/claude@main"

# 4. Exempt refs, quotes, comments, and list items.
pin_case "local action" 0 "./.github/actions/x"
pin_case "docker image" 0 "docker://alpine:3.20"
pin_case "double-quoted SHA" 0 "\"actions/checkout@$SHA\""
pin_case "single-quoted devkit" 0 "'$DEVKIT@main'"
pin_case "SHA with version comment" 0 "actions/checkout@$SHA # v4"

d="$TMPROOT/list"; mkdir -p "$d"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@%s # v4\n      - uses: actions/setup-node@v4\n' "$SHA" > "$d/w.yaml"
err="$("$SCRIPT" "$d" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$err" = "$d/w.yaml:5: 'actions/setup-node@v4' is not pinned to a full commit SHA." ]; then
    pass "list items in a .yaml file: only the tag line fails"
else
    fail "list items in a .yaml file" "exit: $rc" "stderr: [$err]"
fi

# 5. Two bad lines give two stderr lines and exit 1.
d="$TMPROOT/two"; mkdir -p "$d"
printf 'jobs:\n  a:\n    uses: %s@main\n  b:\n    steps:\n      - uses: actions/checkout@v4\n' "unibrain1/devkit-sandbox/.github/workflows/claude.yml" > "$d/w.yml"
err="$("$SCRIPT" "$d" 2>&1 >/dev/null)"; rc=$?
n="$(printf '%s\n' "$err" | grep -c 'is not pinned')"
if [ "$rc" -eq 1 ] && [ "$n" -eq 2 ] \
    && printf '%s\n' "$err" | grep -qF "$d/w.yml:3:" \
    && printf '%s\n' "$err" | grep -qF "$d/w.yml:6:"; then
    pass "two bad lines: two stderr lines, exit 1"
else
    fail "two bad lines" "exit: $rc, lines: $n" "stderr: [$err]"
fi

# 6. A missing folder exits 2 with a message. An empty folder exits 0.
err="$("$SCRIPT" "$TMPROOT/no-such-folder" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qF "$TMPROOT/no-such-folder"; then
    pass "missing folder: exit 2, stderr names the folder"
else
    fail "missing folder" "exit: $rc" "stderr: [$err]"
fi
d="$TMPROOT/empty"; mkdir -p "$d"
err="$("$SCRIPT" "$d" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$err" ]; then
    pass "empty folder: exit 0"
else
    fail "empty folder" "exit: $rc" "stderr: [$err]"
fi

# 7. With no argument, the script scans .github/workflows of the current
# folder. On the real repo, it exits 0.
d="$TMPROOT/noarg"; mkdir -p "$d/.github/workflows"
printf 'jobs:\n  a:\n    uses: actions/checkout@v4\n' > "$d/.github/workflows/w.yml"
err="$(cd "$d" && "$SCRIPT" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$err" = ".github/workflows/w.yml:3: 'actions/checkout@v4' is not pinned to a full commit SHA." ]; then
    pass "no argument: scans .github/workflows of the current folder"
else
    fail "no argument" "exit: $rc" "stderr: [$err]"
fi
err="$(cd "$TMPROOT" && "$SCRIPT" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 2 ]; then
    pass "no argument, no .github/workflows: exit 2"
else
    fail "no argument, no .github/workflows" "exit: $rc" "stderr: [$err]"
fi
err="$(cd "$REAL_REPO" && "$SCRIPT" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 0 ]; then
    pass "real repo: exit 0"
else
    fail "real repo" "exit: $rc" "stderr: [$err]"
fi

# 8. A file that grep cannot read exits 2. A root user can read the file,
# so the case cannot run as root.
if [ "$(id -u)" -eq 0 ]; then
    pass "unreadable file: skipped as root"
else
    d="$TMPROOT/unreadable"; mkdir -p "$d"
    printf 'jobs:\n  a:\n    uses: actions/checkout@%s\n' "$SHA" > "$d/w.yml"
    chmod 000 "$d/w.yml"
    err="$("$SCRIPT" "$d" 2>&1 >/dev/null)"; rc=$?
    chmod 644 "$d/w.yml"
    if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qF "check-action-pins: cannot read '$d'."; then
        pass "unreadable file: exit 2, stderr names the folder"
    else
        fail "unreadable file" "exit: $rc" "stderr: [$err]"
    fi
fi

# 9. A uses value on the next line is a value that the script cannot read.
# It fails. The script does not see "uses:" in a flow mapping
# ("- {uses: x@y}"), so no case tests that (a known limit).
d="$TMPROOT/nextline"; mkdir -p "$d"
printf 'jobs:\n  a:\n    uses:\n      actions/checkout@v4\n' > "$d/w.yml"
err="$("$SCRIPT" "$d" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$err" = "$d/w.yml:3: cannot read the uses value." ]; then
    pass "uses value on the next line: exit 1"
else
    fail "uses value on the next line" "exit: $rc" "stderr: [$err]"
fi

harness_report
