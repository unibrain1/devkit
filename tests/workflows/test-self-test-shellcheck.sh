#!/bin/bash
#
# Tests that the shellcheck step in .github/workflows/self-test.yml is
# pinned: SHELLCHECK_VERSION equals the version that README.md names for a
# local install, SHELLCHECK_SHA256 is a 64-digit hex value, the step checks
# the download with `sha256sum -c`, and the step runs no shellcheck from
# PATH. A shellcheck from PATH can differ from the pinned version, and then
# local lint and CI lint give different findings.
#
# Usage: bash tests/workflows/test-self-test-shellcheck.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$REAL_REPO/.github/workflows/self-test.yml"
README="$REAL_REPO/README.md"

TMPROOT="$(mktemp -d)" || exit 1

# step_fields <workflow> <out-dir>
# Writes the env values and the run text of the step named shellcheck to
# <out-dir>/version, <out-dir>/sha and <out-dir>/run. A missing value gives
# an empty file. Returns 1 when the step is absent or the file is not YAML.
step_fields() {
    mkdir -p "$2" || return 1
    ruby -ryaml -e '
        doc = YAML.safe_load(File.read(ARGV[0]))
        step = (doc["jobs"] || {}).values.flat_map { |j| j["steps"] || [] }
                                  .find { |s| s["name"] == "shellcheck" }
        exit 1 if step.nil?
        env = step["env"] || {}
        File.write(File.join(ARGV[1], "version"), env["SHELLCHECK_VERSION"].to_s)
        File.write(File.join(ARGV[1], "sha"), env["SHELLCHECK_SHA256"].to_s)
        File.write(File.join(ARGV[1], "run"), step["run"].to_s)
    ' "$1" "$2"
}

# check_pin <workflow> <readme> <work-dir>
# Prints one reason for each broken rule. Returns 1 when any rule is broken.
check_pin() {
    local wf="$1" rd="$2" dir="$3" bad=0 version sha readme_versions
    if ! step_fields "$wf" "$dir"; then
        echo "no step named shellcheck in $wf"
        return 1
    fi
    version="$(cat "$dir/version")"
    sha="$(cat "$dir/sha")"
    readme_versions="$(grep -oE 'shellcheck [0-9]+\.[0-9]+\.[0-9]+' "$rd" | sed 's/^shellcheck //' | sort -u)"
    if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "SHELLCHECK_VERSION is not X.Y.Z: [$version]"
        bad=1
    elif [ "$readme_versions" != "$version" ]; then
        echo "README names [$(printf '%s' "$readme_versions" | tr '\n' ' ')], the workflow pins [$version]"
        bad=1
    fi
    if ! printf '%s' "$sha" | grep -qE '^[0-9a-f]{64}$'; then
        echo "SHELLCHECK_SHA256 is not 64 hex digits: [$sha]"
        bad=1
    fi
    if ! grep -qE 'sha256sum -c' "$dir/run"; then
        echo "the step does not run sha256sum -c"
        bad=1
    fi
    if grep -qE '(^|[[:space:];&|(])shellcheck([[:space:]]|$)' "$dir/run"; then
        echo "the step calls shellcheck from PATH"
        bad=1
    fi
    return "$bad"
}

# --- The real files -------------------------------------------------------
if [ ! -f "$WORKFLOW" ] || [ ! -f "$README" ]; then
    fail "workflow and README exist" "$WORKFLOW" "$README"
    harness_report
fi

if WHY="$(check_pin "$WORKFLOW" "$README" "$TMPROOT/real")"; then
    pass "shellcheck step is pinned, checked, and matches README.md"
else
    fail "shellcheck step is pinned, checked, and matches README.md" "$WHY"
fi

# --- Negative controls: each changed copy must fail -----------------------
# expect_broken <label> <workflow> <readme>
expect_broken() {
    local label="$1" out
    if out="$(check_pin "$2" "$3" "$TMPROOT/ctl")"; then
        fail "control: $label fails the check"
    else
        pass "control: $label fails the check ($out)"
    fi
}

CTL="$TMPROOT/copies"
mkdir -p "$CTL"

sed 's/shellcheck 0\.11\.0/shellcheck 0.10.0/' "$README" > "$CTL/readme-old.md"
expect_broken "README names another version" "$WORKFLOW" "$CTL/readme-old.md"

sed 's/SHELLCHECK_VERSION: 0\.11\.0/SHELLCHECK_VERSION: 0.10.0/' "$WORKFLOW" > "$CTL/wf-version.yml"
expect_broken "workflow pins another version" "$CTL/wf-version.yml" "$README"

sed 's/\(SHELLCHECK_SHA256: \).*/\1abc123/' "$WORKFLOW" > "$CTL/wf-sha.yml"
expect_broken "short SHELLCHECK_SHA256" "$CTL/wf-sha.yml" "$README"

sed 's/sha256sum -c -/cat/' "$WORKFLOW" > "$CTL/wf-nosum.yml"
expect_broken "no sha256sum -c" "$CTL/wf-nosum.yml" "$README"

# shellcheck disable=SC2016 # the sed pattern holds a literal $
sed 's/^\( *\)"\$shellcheck" plugins/\1shellcheck plugins/' "$WORKFLOW" > "$CTL/wf-path.yml"
expect_broken "bare shellcheck from PATH" "$CTL/wf-path.yml" "$README"

# A control that changed nothing would prove nothing: the sed edits must differ.
for f in wf-version.yml wf-sha.yml wf-nosum.yml wf-path.yml; do
    if cmp -s "$WORKFLOW" "$CTL/$f"; then
        fail "control copy $f differs from the workflow"
    fi
done
if cmp -s "$README" "$CTL/readme-old.md"; then
    fail "control copy readme-old.md differs from README.md"
fi

harness_report
