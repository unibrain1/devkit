#!/bin/bash
#
# Tests for the supply-chain pins of issue #151: a Dependabot cooldown in
# each entry of devkit's own dependabot.yml and of each template
# dependabot.yml, a full Node version in each template .nvmrc and in
# self-test.yml, and the katex override in package.json.
#
# Env overrides, for the break-it checks on scratch copies:
#   REPO_ROOT  the repo folder to check
#   NO_CONTROLS  set to 1 to skip the break-it checks
#
# Usage: bash tests/templates/test-dependabot-cooldown.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="${REPO_ROOT:-$REAL_REPO}"

TMPROOT="$(mktemp -d)" || exit 1

# The lowest Node versions with the fix for CVE-2026-111497 (issue #151).
NODE24_MIN="24.22.1"
NODE22_MIN="22.23.4"
KATEX_MIN="0.18.2"

if command -v ruby >/dev/null 2>&1 && ruby -ryaml -rjson -e 'exit 0' 2>/dev/null \
    && command -v jq >/dev/null 2>&1; then
    pass "ruby with yaml and json, and jq, are available"
else
    fail "ruby with yaml and json, and jq, are available" "install ruby and jq"
    harness_report
fi

# version_ge <a> <b>: exit 0 when the X.Y.Z version a is at or above b.
version_ge() {
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<EOF
$1
EOF
    IFS=. read -r b1 b2 b3 <<EOF
$2
EOF
    [ "$a1" -gt "$b1" ] && return 0
    [ "$a1" -lt "$b1" ] && return 1
    [ "$a2" -gt "$b2" ] && return 0
    [ "$a2" -lt "$b2" ] && return 1
    [ "$a3" -ge "$b3" ]
}

is_full_version() {
    printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

# --- 1. cooldown in each Dependabot entry ------------------------------
L_COOLDOWN="each dependabot.yml entry has cooldown default-days 7"
bad=""
for f in "$ROOT/.github/dependabot.yml" "$ROOT"/plugins/flow/templates/*/.github/dependabot.yml; do
    [ -f "$f" ] || continue
    # The container-ghcr stack entry is a quoted placeholder. It parses as
    # a plain string, so the file parses as it is.
    # A parse error must fail the check, so read the JSON before jq.
    if ! json="$(ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$f" 2>/dev/null)" \
        || ! got="$(printf '%s' "$json" | jq -er '[.updates[] | select(.cooldown != {"default-days": 7}) | .["package-ecosystem"]] | join(",")')"; then
        bad="$bad ${f#"$ROOT"/}:parse-error"
    elif [ -n "$got" ]; then
        bad="$bad ${f#"$ROOT"/}:$got"
    fi
done
if [ -z "$bad" ]; then
    pass "$L_COOLDOWN"
else
    fail "$L_COOLDOWN" "entries with no cooldown:$bad"
fi

# --- 2. full Node version in each template .nvmrc ----------------------
L_NVMRC="each template .nvmrc holds a full Node version at or above $NODE24_MIN"
bad=""
n=0
for f in "$ROOT"/plugins/flow/templates/*/.nvmrc; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    v="$(cat "$f")"
    if ! is_full_version "$v" || ! version_ge "$v" "$NODE24_MIN"; then
        bad="$bad ${f#"$ROOT"/}:$v"
    fi
done
if [ "$n" -ge 2 ] && [ -z "$bad" ]; then
    pass "$L_NVMRC"
else
    fail "$L_NVMRC" "files: $n, bad:$bad"
fi

# --- 3. full Node version in self-test.yml -----------------------------
L_SELFTEST="self-test.yml node-version is a full version at or above $NODE22_MIN"
v="$(sed -n 's/^ *node-version: *\([^ #]*\).*$/\1/p' "$ROOT/.github/workflows/self-test.yml")"
if [ "$(printf '%s\n' "$v" | grep -c .)" -eq 1 ] && is_full_version "$v" && version_ge "$v" "$NODE22_MIN"; then
    pass "$L_SELFTEST"
else
    fail "$L_SELFTEST" "node-version: $v"
fi

# --- 4. katex override -------------------------------------------------
L_KATEX="package.json overrides katex for micromark-extension-math, lockfile katex at or above $KATEX_MIN"
ov="$(jq -r '.overrides["micromark-extension-math"].katex // empty' "$ROOT/package.json")"
lk="$(jq -r '.packages["node_modules/katex"].version // empty' "$ROOT/package-lock.json")"
if [ "$ov" = "^$KATEX_MIN" ] && is_full_version "$lk" && version_ge "$lk" "$KATEX_MIN"; then
    pass "$L_KATEX"
else
    fail "$L_KATEX" "override: ${ov:-none}, lockfile: ${lk:-none}"
fi

# --- break-it checks ---------------------------------------------------
# Each check changes one file in a scratch copy and runs this test on it.
# The run must fail with the label of the changed rule.
control() {
    local name="$1" expect="$2" mutation="$3" C out rc
    C="$TMPROOT/copy-$name"
    mkdir -p "$C/.github/workflows" "$C/plugins/flow"
    cp "$ROOT/.github/dependabot.yml" "$C/.github/"
    cp "$ROOT/.github/workflows/self-test.yml" "$C/.github/workflows/"
    cp -R "$ROOT/plugins/flow/templates" "$C/plugins/flow/templates"
    cp "$ROOT/package.json" "$ROOT/package-lock.json" "$C/"
    (cd "$C" && eval "$mutation")
    out="$(REPO_ROOT="$C" NO_CONTROLS=1 bash "$SELF" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF -- "FAIL: $expect"; then
        pass "control $name: check failed as expected"
    else
        fail "control $name: check did not fail as expected" "expected: FAIL: $expect" \
            "$(printf '%s\n' "$out" | grep -E '^(FAIL|[0-9]+ scenario)' | head -3 | tr '\n' ' ')"
    fi
}

# sub <file> <sed-expr>: edit a file in place, on macOS and Linux.
sub() {
    sed -e "$2" "$1" > "$1.new" && mv "$1.new" "$1"
}

if [ "${NO_CONTROLS:-0}" != 1 ]; then
    control devkit-no-cooldown "$L_COOLDOWN" \
        'sub .github/dependabot.yml "/cooldown:/,/default-days/d"'
    control stack-no-cooldown "$L_COOLDOWN" \
        'sub plugins/flow/templates/container-ghcr/.github/dependabot.yml "/stack_ecosystem/,\$ {/cooldown:/d; /default-days/d;}"'
    control cooldown-1-day "$L_COOLDOWN" \
        'sub plugins/flow/templates/ios-app/.github/dependabot.yml "s/default-days: 7/default-days: 1/"'
    control dependabot-bad-yaml "$L_COOLDOWN" \
        'printf "updates: [\n" > plugins/flow/templates/baseline/.github/dependabot.yml'
    control nvmrc-major-only "$L_NVMRC" \
        'printf "24\n" > plugins/flow/templates/static-site-host/.nvmrc'
    control nvmrc-old-patch "$L_NVMRC" \
        'printf "24.22.0\n" > plugins/flow/templates/static-site-cloudflare/.nvmrc'
    control selftest-major-only "$L_SELFTEST" \
        'sub .github/workflows/self-test.yml "s/node-version: .*/node-version: 22/"'
    control katex-no-override "$L_KATEX" \
        'jq "del(.overrides)" package.json > p.new && mv p.new package.json'
    control katex-old-lock "$L_KATEX" \
        'jq ".packages[\"node_modules/katex\"].version = \"0.16.47\"" package-lock.json > l.new && mv l.new package-lock.json'
fi

harness_report
