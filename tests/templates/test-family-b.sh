#!/bin/bash
#
# Tests for the Family B template: plugins/flow/templates/container-ghcr/ (the
# files of a new container image repo, at the paths that the target repo
# uses).
#
# Checks: the exact file set, the baseline paths that container-ghcr
# overrides (the allowed set comes from the override table in
# docs/families.md), the dependabot and pre-commit override content, YAML
# and JSON validity and the YAML placeholder form, the container-image.yml
# caller, the ci.yml triggers, permissions, and App job, the Dependabot
# ecosystems, the concurrency group, the local hadolint and test-quick
# hooks and the hadolint image pin, the
# devkit pin rule, flow-project-check and the keys of project.md,
# settings.json against templates/settings.json, CLAUDE.md, placeholders,
# project facts, the .gitignore effect (git check-ignore), the .dockerignore
# rules, whitespace, and the container-ghcr manual steps.
#
# Override check: it is semantic, as in test-family-w.sh. Every entry of the
# baseline file must be present, equal, in the parsed override, and the
# other top-level keys must be equal. A second check requires every line of
# the baseline file, comments too, in the override.
#
# YAML placeholder check: comments count too. After the ${{ ... }} GitHub
# expressions are removed, each line that holds "{{" must be one key with
# the quoted value "{{key}}" and nothing more.
#
# Each check has a break-it control. The control copies the inputs to a
# scratch folder, breaks one thing, runs this script on the copy, and
# expects the named check to fail. Set FAMILY_B_NO_CONTROLS=1 to skip them.
#
# Env overrides, for the controls on scratch copies:
#   TEMPLATES_DIR      the templates folder: baseline/, container-ghcr/, web-app/, claude-block.md
#   BASELINE_DIR       the baseline folder (default: $TEMPLATES_DIR/baseline)
#   FAMILIES_DOC       docs/families.md
#   SETTINGS_TEMPLATE  templates/settings.json
#   FLOW_BIN           the folder with flow-project-check and flow-project-fact
#   PIN_CHECK          .github/scripts/check-action-pins.sh
#
# Usage: bash tests/templates/test-family-b.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# SC2016: the control mutations are single-quoted on purpose. eval expands
# them inside the control. SC2034: eval reads CG. SC2155: a local that holds
# a command result needs no exit status.
# shellcheck disable=SC2016,SC2034,SC2155

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATES_DIR="${TEMPLATES_DIR:-$REAL_REPO/plugins/flow/templates}"
BASELINE_DIR="${BASELINE_DIR:-$TEMPLATES_DIR/baseline}"
FAMILIES_DOC="${FAMILIES_DOC:-$REAL_REPO/docs/families.md}"
SETTINGS_TEMPLATE="${SETTINGS_TEMPLATE:-$REAL_REPO/templates/settings.json}"
FLOW_BIN="${FLOW_BIN:-$REAL_REPO/plugins/flow/bin}"
PIN_CHECK="${PIN_CHECK:-$REAL_REPO/.github/scripts/check-action-pins.sh}"
CLAUDE_BLOCK="$TEMPLATES_DIR/claude-block.md"
CONTAINER="$TEMPLATES_DIR/container-ghcr"
WEB_APP="$TEMPLATES_DIR/web-app"

TMPROOT="$(mktemp -d)" || exit 1

# Names that must not appear in a template: they are project facts. The
# match is case-sensitive.
DENY_LIST="MyGunLog ElanRegistry Registry TeamCroc BurgessMachineWorks BurgessGunWorks devkit-sandbox"

# A fake 40-hex commit SHA for the devkit pin rewrite.
FAKE_SHA="0123456789abcdef0123456789abcdef01234567"

CALLER_USES="unibrain1/devkit/.github/workflows/container-image.yml@main"

# --- Ruby helper -------------------------------------------------------
# y2j.rb <out-dir> <file>...: one Ruby start parses every file. For each file
# that parses, it writes the JSON to <out-dir>/<path with / as _>. A file that
# does not parse gets no output file. Ruby (YAML 1.1) reads the key `on` as
# true, so the helper renames a true key to "on".
cat > "$TMPROOT/y2j.rb" <<'RUBY'
require "yaml"
require "json"
def fix(o)
  case o
  when Hash then o.each_with_object({}) { |(k, v), h| h[k == true ? "on" : k.to_s] = fix(v) }
  when Array then o.map { |v| fix(v) }
  else o
  end
end
out = ARGV.shift
ARGV.each do |f|
  begin
    File.write(File.join(out, f.tr("/", "_")), JSON.generate(fix(YAML.safe_load(File.read(f), aliases: false))))
  rescue StandardError, Psych::SyntaxError
    next
  end
end
RUBY

if command -v ruby >/dev/null 2>&1 && ruby -ryaml -rjson -e 'exit 0' 2>/dev/null \
    && command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    pass "ruby with yaml and json, jq, and git are available"
else
    fail "ruby with yaml and json, jq, and git are available" "install ruby, jq, and git"
    harness_report
fi

# y2j <file>: JSON on stdout, nonzero on a parse error. The file must be in
# the cache that the next two lines fill.
YJ="$TMPROOT/yj"; mkdir -p "$YJ"
# shellcheck disable=SC2046 # the file names hold no space
ruby "$TMPROOT/y2j.rb" "$YJ" $(find "$CONTAINER" "$BASELINE_DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort -u) 2>/dev/null
y2j() { local c="$YJ/$(printf '%s' "$1" | tr / _)"; [ -f "$c" ] && cat "$c"; }

# files_in <dir>: each file below <dir>, as a relative path, sorted.
files_in() {
    (cd "$1" 2>/dev/null && find . -type f ! -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort)
}

# strip_gha <file>: the file with each ${{ ... }} GitHub expression removed.
strip_gha() { sed -E 's/\$\{\{[^}]*\}\}//g' "$1"; }

# scratch_git <dir>: a new git repo with a scratch HOME, so that no user or
# system git config (for example commit signing) changes the result.
scratch_git() {
    rm -rf "$1"; mkdir -p "$1/home"
    (cd "$1" && HOME="$1/home" GIT_CONFIG_NOSYSTEM=1 git init -q . 2>/dev/null)
}

# flow_block <file>: the lines from "<!-- flow:begin" to "<!-- flow:end -->".
flow_block() {
    awk '/^<!-- flow:begin/{p=1} p{print} /^<!-- flow:end -->$/{p=0}' "$1" 2>/dev/null
}

# doc_overrides: the Override paths of the container-ghcr rows in the
# override table of docs/families.md, one on each line, sorted.
doc_overrides() {
    sed -nE 's/^\| `container-ghcr` \| `([^`]+)` \|.*/\1/p' "$FAMILIES_DOC" 2>/dev/null | LC_ALL=C sort -u
}

# override_holds_baseline <rel> <list key> <entry label key>: prints each
# problem. The baseline file and the override must have equal top-level keys
# except <list key>, and each baseline <list key> entry must be in the
# override. Each line of the baseline file must be in the override.
override_holds_baseline() {
    local rel="$1" key="$2" label="$3" base over
    base="$(y2j "$BASELINE_DIR/$rel")"
    over="$(y2j "$CONTAINER/$rel")"
    if [ -z "$base" ]; then
        echo "baseline $rel is missing or does not parse"
        return
    fi
    printf '%s' "$base" | jq -r --argjson f "${over:-null}" --arg k "$key" --arg l "$label" '
        . as $b
        | [ (if ($b | del(.[$k])) == (($f // {}) | del(.[$k])) then empty else "top-level keys" end),
            ($b[$k][] | . as $e
                | select(any((($f // {})[$k] // [])[]; . == $e) | not)
                | $k + " " + (.[$l] | tostring)) ] | join(", ")' 2>&1
    grep -vxFf "$CONTAINER/$rel" "$BASELINE_DIR/$rel" 2>/dev/null | sed 's/^/ line missing: /' | tr '\n' ' '
}

# --- the checks --------------------------------------------------------
# check_whitespace <label> <dir> <files>: no trailing whitespace, no tab in
# YAML, not empty, one final newline.
check_whitespace() {
    local label="$1" dir="$2" files="$3" f rel got=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel=""
        grep -qE '[[:space:]]+$' "$dir/$f" && rel="$rel trailing-whitespace"
        case "$f" in
            *.yml|*.yaml) grep -q "$(printf '\t')" "$dir/$f" && rel="$rel tab" ;;
        esac
        if [ ! -s "$dir/$f" ]; then
            rel="$rel empty"
        elif [ -n "$(tail -c1 "$dir/$f")" ]; then
            rel="$rel no-final-newline"
        elif [ "$(tail -c2 "$dir/$f" | od -An -tx1 | tr -d ' \n')" = "0a0a" ]; then
            rel="$rel extra-final-newline"
        fi
        [ -z "$rel" ] || got="$got [$f:$rel]"
    done <<EOF
$files
EOF
    if [ -z "$got" ] && [ -n "$files" ]; then
        pass "$label: clean whitespace"
    else
        fail "$label: clean whitespace" "problems:${got:- (no files)}"
    fi
}

check_family_b() {
    local want got f rel rc files base_files allowed pcj cij capj depj repo
    files="$(files_in "$CONTAINER")"
    base_files="$(files_in "$BASELINE_DIR")"

    # 1. exact file set
    want=".claude/project.md
.claude/rules/image-review.md
.claude/settings.json
.dockerignore
.github/dependabot.yml
.github/workflows/ci.yml
.github/workflows/container-image.yml
.gitignore
.pre-commit-config.yaml
CLAUDE.md"
    if [ "$files" = "$want" ]; then
        pass "container-ghcr: file set is exact"
    else
        fail "container-ghcr: file set is exact" "got: $(printf '%s' "$files" | tr '\n' ' ')"
    fi

    # 2. the overrides are the container-ghcr rows of the docs table
    allowed="$(doc_overrides)"
    got=""
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        if [ -e "$CONTAINER/$rel" ] && ! printf '%s\n' "$allowed" | grep -qFx -- "$rel"; then
            got="$got [not in the table: $rel]"
        fi
    done <<EOF
$base_files
EOF
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        printf '%s\n' "$base_files" | grep -qFx -- "$rel" || got="$got [not a baseline path: $rel]"
        [ -e "$CONTAINER/$rel" ] || got="$got [no file: $rel]"
    done <<EOF
$allowed
EOF
    if [ -z "$got" ] && [ -n "$allowed" ] && [ -n "$base_files" ]; then
        pass "container-ghcr: the overrides are the container-ghcr rows of the docs table"
    else
        fail "container-ghcr: the overrides are the container-ghcr rows of the docs table" \
            "problems:${got:- (no container-ghcr rows, or baseline folder empty)}"
    fi

    # 3. each YAML and JSON file parses
    pcj="{}"; cij="{}"; capj="{}"; depj="{}"
    while IFS= read -r rel; do
        case "$rel" in
            *.yml|*.yaml) ;;
            *) continue ;;
        esac
        if f="$(y2j "$CONTAINER/$rel")"; then
            pass "container-ghcr: parses: $rel"
            case "$rel" in
                .pre-commit-config.yaml) pcj="$f" ;;
                .github/workflows/ci.yml) cij="$f" ;;
                .github/workflows/container-image.yml) capj="$f" ;;
                .github/dependabot.yml) depj="$f" ;;
            esac
        else
            fail "container-ghcr: parses: $rel"
        fi
    done <<EOF
$files
EOF
    if jq empty "$CONTAINER/.claude/settings.json" >/dev/null 2>&1; then
        pass "container-ghcr: parses: .claude/settings.json"
    else
        fail "container-ghcr: parses: .claude/settings.json"
    fi

    # 4. each override holds the baseline content
    got="$(override_holds_baseline .github/dependabot.yml updates package-ecosystem)"
    if [ -z "$got" ]; then
        pass "container-ghcr: dependabot override holds the baseline content"
    else
        fail "container-ghcr: dependabot override holds the baseline content" "$got"
    fi
    got="$(override_holds_baseline .pre-commit-config.yaml repos repo)"
    if [ -z "$got" ]; then
        pass "container-ghcr: pre-commit override holds the baseline content"
    else
        fail "container-ghcr: pre-commit override holds the baseline content" "$got"
    fi

    # 5. YAML placeholders are full quoted values
    got=""
    while IFS= read -r rel; do
        case "$rel" in
            *.yml|*.yaml) ;;
            *) continue ;;
        esac
        f="$(strip_gha "$CONTAINER/$rel" | grep -F '{{' \
            | grep -vE '^[[:space:]]*(-[[:space:]]+)?([A-Za-z0-9_-]+:[[:space:]]+)?"\{\{[a-z_]+\}\}"[[:space:]]*$')"
        [ -z "$f" ] || got="$got [$rel: $(printf '%s' "$f" | tr '\n' '|')]"
    done <<EOF
$files
EOF
    if [ -z "$got" ]; then
        pass "container-ghcr: each YAML placeholder is a full quoted value"
    else
        fail "container-ghcr: each YAML placeholder is a full quoted value" "bad:$got"
    fi

    # 6. the container-image.yml caller
    got="$(printf '%s' "$capj" | jq -r '[.jobs // {} | to_entries[] | select(.value.uses != null) | .key + "=" + .value.uses] | join(" ")')"
    if [ "$got" = "image=$CALLER_USES" ]; then
        pass "container-ghcr: the caller job image uses container-image.yml@main"
    else
        fail "container-ghcr: the caller job image uses container-image.yml@main" "got: ${got:-none}"
    fi
    got="$(printf '%s' "$capj" | jq -c '.jobs.image.permissions')"
    if [ "$got" = '{"contents":"read","packages":"write"}' ]; then
        pass "container-ghcr: the image job permissions are contents: read and packages: write"
    else
        fail "container-ghcr: the image job permissions are contents: read and packages: write" "got: $got"
    fi
    got="$(printf '%s' "$capj" | jq -c '(.on // {}) | [
        (if type == "object" and has("pull_request") and (.pull_request == null or .pull_request == {}) then "pr" else empty end),
        (.push.branches? // null), (.push.tags? // null), (keys? // [])]')"
    if [ "$got" = '["pr",["main"],["v[0-9]+.[0-9]+.[0-9]+"],["pull_request","push"]]' ]; then
        pass "container-ghcr: the caller runs on each PR, a push to main, and a strict vX.Y.Z tag"
    else
        fail "container-ghcr: the caller runs on each PR, a push to main, and a strict vX.Y.Z tag" "got: $got"
    fi
    got="$(printf '%s' "$capj" | jq -c '[.concurrency.group, .concurrency["cancel-in-progress"]]')"
    if [ "$got" = "[\"\${{ github.workflow }}-\${{ startsWith(github.ref, 'refs/tags/') && 'release' || github.ref }}\",\"\${{ github.event_name == 'pull_request' }}\"]" ]; then
        pass "container-ghcr: the caller puts all tag runs in one concurrency group, and cancels only a PR run"
    else
        fail "container-ghcr: the caller puts all tag runs in one concurrency group, and cancels only a PR run" "got: $got"
    fi
    got="$(printf '%s' "$capj" | jq -r '[.jobs[]? | has("with")] | any')"
    if [ "$got" = false ] && grep -Eq '^[[:space:]]*#[[:space:]]*with:' "$CONTAINER/.github/workflows/container-image.yml" 2>/dev/null; then
        pass "container-ghcr: the caller has no with:, and a comment shows it"
    else
        fail "container-ghcr: the caller has no with:, and a comment shows it" "with in a job: $got"
    fi

    # 7. ci.yml
    got="$(printf '%s' "$cij" | jq -c '(.on // {}) | if type == "object" and has("pull_request") then .pull_request else "absent" end')"
    if [ "$got" = null ] || [ "$got" = '{}' ]; then
        pass "container-ghcr: ci.yml runs on each pull_request, with no filter"
    else
        fail "container-ghcr: ci.yml runs on each pull_request, with no filter" "pull_request: $got"
    fi
    got="$(printf '%s' "$cij" | jq -c '.on.push.branches')"
    if [ "$got" = '["main","milestone/**"]' ]; then
        pass "container-ghcr: ci.yml push branches are main and milestone/**"
    else
        fail "container-ghcr: ci.yml push branches are main and milestone/**" "got: $got"
    fi
    got="$(printf '%s' "$cij" | jq -c '.permissions')"
    if [ "$got" = '{"contents":"read"}' ]; then
        pass "container-ghcr: ci.yml permissions are contents: read"
    else
        fail "container-ghcr: ci.yml permissions are contents: read" "got: $got"
    fi
    got="$(printf '%s' "$cij" | jq -r '.jobs.app.name // "(none)"')"
    if [ "$got" = App ]; then
        pass "container-ghcr: ci.yml has the job app with the name App"
    else
        fail "container-ghcr: ci.yml has the job app with the name App" "name: $got"
    fi
    got="$(printf '%s' "$cij" | jq -r '[.jobs.app.steps[]?.run // empty] as $r
        | [("{{lint}}", "{{test}}") | select(. as $c | $r | index($c) | not)] | join(" ")')"
    if [ -z "$got" ]; then
        pass "container-ghcr: ci.yml App job runs {{lint}} and {{test}}"
    else
        fail "container-ghcr: ci.yml App job runs {{lint}} and {{test}}" "no step runs: $got"
    fi
    if [ -f "$PIN_CHECK" ] && [ -d "$CONTAINER/.github/workflows" ]; then
        got="$(bash "$PIN_CHECK" "$CONTAINER/.github/workflows" 2>&1)"; rc=$?
        if [ "$rc" -eq 0 ]; then
            pass "container-ghcr: check-action-pins.sh passes on the workflows"
        else
            fail "container-ghcr: check-action-pins.sh passes on the workflows" "exit: $rc" "$got"
        fi
    else
        fail "container-ghcr: check-action-pins.sh passes on the workflows" "script or folder missing"
    fi

    # 8. Dependabot entries
    got="$(printf '%s' "$depj" | jq -r '[.updates[]?["package-ecosystem"]] | sort | join(" ")')"
    if [ "$got" = 'docker github-actions {{stack_ecosystem}}' ]; then
        pass "container-ghcr: dependabot ecosystems are github-actions, docker, and {{stack_ecosystem}}"
    else
        fail "container-ghcr: dependabot ecosystems are github-actions, docker, and {{stack_ecosystem}}" "got: $got"
    fi
    if grep -qxF '  - package-ecosystem: "{{stack_ecosystem}}"' "$CONTAINER/.github/dependabot.yml" 2>/dev/null; then
        pass "container-ghcr: dependabot stack entry is the quoted \"{{stack_ecosystem}}\""
    else
        fail "container-ghcr: dependabot stack entry is the quoted \"{{stack_ecosystem}}\""
    fi
    rel="$(y2j "$BASELINE_DIR/.github/dependabot.yml" | jq -r '.updates[0]["commit-message"].prefix' 2>/dev/null)"
    got="$(printf '%s' "$depj" | jq -r --arg p "$rel" '
        [.updates[]? | select(.["package-ecosystem"] != "github-actions")
         | select(.["commit-message"].prefix != $p or .schedule.interval != "weekly"
                  or .directory != "/" or ((.groups // {}) | length) != 1)
         | .["package-ecosystem"]] | join(",")')"
    if [ -z "$got" ] && [ -n "$rel" ] && [ "$rel" != null ]; then
        pass "container-ghcr: new dependabot entries are weekly, grouped, at /, with the baseline prefix"
    else
        fail "container-ghcr: new dependabot entries are weekly, grouped, at /, with the baseline prefix" \
            "baseline prefix: $rel" "bad entries: $got"
    fi

    # 9. pre-commit: the local hadolint and test-quick hooks. The upstream
    # hadolint-docker hook names the image with no tag, so no repo entry may
    # point at hadolint/hadolint.
    got="$(printf '%s' "$pcj" | jq -r '[.repos[]? | select((.repo // "") | test("hadolint"))] | length' 2>&1)"
    if [ "$got" = 0 ]; then
        pass "container-ghcr: pre-commit has no hadolint repo hook"
    else
        fail "container-ghcr: pre-commit has no hadolint repo hook" "hadolint repos: $got"
    fi
    got="$(printf '%s' "$pcj" | jq -r '
        [.repos[]? | select(.repo == "local") | .hooks[]? | select(.id == "hadolint")] as $h
        | if ($h | length) != 1 then "hadolint hooks: \($h | length)"
          elif $h[0].language != "docker_image" then "language: \($h[0].language)"
          elif $h[0].types != ["dockerfile"] then "types: \($h[0].types)"
          elif ($h[0].entry | type) != "string"
               or ($h[0].entry | test("^ghcr\\.io/hadolint/hadolint:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[0-9a-f]{64} hadolint$") | not)
            then "entry: \($h[0].entry)"
          else empty end' 2>&1)"
    if [ -z "$got" ]; then
        pass "container-ghcr: the local hadolint hook pins the image by tag and digest"
    else
        fail "container-ghcr: the local hadolint hook pins the image by tag and digest" "$got"
    fi
    got="$(printf '%s' "$pcj" | jq -r '
        [.repos[]? | select(.repo == "local") | .hooks[]?] as $h
        | if ([$h[] | select(.id == "test-quick" and .entry == "bash" and .args == ["-c", "{{test_quick}}"]
                and .language == "system" and .pass_filenames == false)] | length) == 1
             and ([$h[].id] == ["hadolint", "test-quick"])
          then empty else "local hooks: \([$h[].id] | join(","))" end' 2>&1)"
    if [ -z "$got" ]; then
        pass "container-ghcr: pre-commit local hooks are hadolint and test-quick"
    else
        fail "container-ghcr: pre-commit local hooks are hadolint and test-quick" "$got"
    fi

    # 10. devkit pin rule
    got="$(grep -rhE '^[[:space:]-]*uses:[[:space:]]*unibrain1/devkit/' "$BASELINE_DIR" "$CONTAINER" 2>/dev/null)"
    rel="$(printf '%s' "$got" | grep -c .)"
    f="$(printf '%s\n' "$got" | grep . | grep -vE '@main$')"
    if [ "$rel" -gt 0 ] && [ -z "$f" ]; then
        pass "pin rule: each devkit uses line in baseline and container-ghcr ends in @main"
    else
        fail "pin rule: each devkit uses line in baseline and container-ghcr ends in @main" \
            "devkit uses lines: $rel" "not @main: $(printf '%s' "$f" | tr '\n' '|')"
    fi
    repo="$TMPROOT/pin"
    rm -rf "$repo"; mkdir -p "$repo"
    cp -R "$BASELINE_DIR" "$repo/baseline"; cp -R "$CONTAINER" "$repo/container-ghcr"
    got=""
    find "$repo" -type f \( -name '*.yml' -o -name '*.yaml' \) > "$TMPROOT/pin-files"
    while IFS= read -r f; do
        sed -E "s|^([[:space:]-]*uses:[[:space:]]*unibrain1/devkit/[^@[:space:]]+)@main\$|\\1@$FAKE_SHA # v9.9.9|" \
            "$f" > "$f.new" && mv "$f.new" "$f"
    done < "$TMPROOT/pin-files"
    for rel in baseline container-ghcr; do
        [ -d "$repo/$rel/.github/workflows" ] || continue
        f="$(bash "$PIN_CHECK" "$repo/$rel/.github/workflows" 2>&1)" || got="$got [$rel: $f]"
    done
    f="$(grep -rhE '^[[:space:]-]*uses:[[:space:]]*unibrain1/devkit/.*@main' "$repo" 2>/dev/null)"
    [ -z "$f" ] || got="$got [@main left: $f]"
    if [ -z "$got" ]; then
        pass "pin rule: the Devkit pin rewrite passes check-action-pins.sh and leaves no @main"
    else
        fail "pin rule: the Devkit pin rewrite passes check-action-pins.sh and leaves no @main" "$got"
    fi

    # 11. project.md
    repo="$TMPROOT/pc"
    scratch_git "$repo"
    mkdir -p "$repo/.claude"
    cp "$CONTAINER/.claude/project.md" "$repo/.claude/project.md" 2>/dev/null
    got="$(cd "$repo" && "$FLOW_BIN/flow-project-check" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "container-ghcr: flow-project-check passes on project.md"
    else
        fail "container-ghcr: flow-project-check passes on project.md" "exit: $rc" "$got"
    fi
    got=""
    for rel in test test_quick lint plans deploy; do
        f="$(cd "$repo" && "$FLOW_BIN/flow-project-fact" "$rel" 2>/dev/null)" && [ -n "$f" ] || got="$got $rel"
    done
    if [ -z "$got" ]; then
        pass "container-ghcr: project.md has each needed key"
    else
        fail "container-ghcr: project.md has each needed key" "missing:$got"
    fi

    # 12. settings.json
    got="$(jq -S . "$CONTAINER/.claude/settings.json" 2>/dev/null)"
    if [ -n "$got" ] && [ "$got" = "$(jq -S . "$SETTINGS_TEMPLATE" 2>/dev/null)" ]; then
        pass "container-ghcr: settings.json equals templates/settings.json"
    else
        fail "container-ghcr: settings.json equals templates/settings.json"
    fi

    # 13. CLAUDE.md
    got="$(flow_block "$CONTAINER/CLAUDE.md")"
    if [ -n "$got" ] && [ "$got" = "$(cat "$CLAUDE_BLOCK" 2>/dev/null)" ] \
        && [ "$got" = "$(flow_block "$WEB_APP/CLAUDE.md")" ] \
        && [ "$(grep -c '^<!-- flow:begin' "$CONTAINER/CLAUDE.md")" = "1" ]; then
        pass "container-ghcr: CLAUDE.md flow block equals claude-block.md and the web-app block"
    else
        fail "container-ghcr: CLAUDE.md flow block equals claude-block.md and the web-app block"
    fi
    got=""
    for f in '`edge`' '`sha-<7 hex>`' '`X.Y.Z`' '`X.Y`' '`latest`' 'patch tag'; do
        grep -qF -- "$f" "$CONTAINER/CLAUDE.md" 2>/dev/null || got="$got [$f]"
    done
    if [ -z "$got" ]; then
        pass "container-ghcr: CLAUDE.md names the image tags and the hotfix patch tag"
    else
        fail "container-ghcr: CLAUDE.md names the image tags and the hotfix patch tag" "missing:$got"
    fi

    # 14. placeholders, project facts, .gitignore, .dockerignore, whitespace
    got=""
    while IFS= read -r f; do
        [ -f "$CONTAINER/$f" ] || continue
        for rel in $(strip_gha "$CONTAINER/$f" | grep -oE '\{\{[a-z_]+\}\}' | sort -u); do
            grep -qF -- "\`$rel\`" "$FAMILIES_DOC" 2>/dev/null || got="$got $rel($f)"
        done
    done <<EOF
$files
EOF
    if [ -z "$got" ] && [ -f "$FAMILIES_DOC" ]; then
        pass "container-ghcr: each placeholder is listed in docs/families.md"
    else
        fail "container-ghcr: each placeholder is listed in docs/families.md" "not listed:${got:- (families.md missing)}"
    fi
    got=""
    for rel in $DENY_LIST; do
        f="$(grep -rlF -e "$rel" "$CONTAINER" 2>/dev/null | tr '\n' ' ')"
        [ -z "$f" ] || got="$got [$rel: $f]"
    done
    if [ -z "$got" ]; then
        pass "container-ghcr: no project name in a template file"
    else
        fail "container-ghcr: no project name in a template file" "found:$got"
    fi
    # git check-ignore tests the effect of the rules, so a reorder or a later
    # "!" rule that commits a secret fails too. The empty core.excludesFile
    # and the scratch XDG_CONFIG_HOME keep the user's global ignore file out.
    got=""
    repo="$TMPROOT/gitignore-$$"
    scratch_git "$repo"
    if [ -f "$CONTAINER/.gitignore" ] && cp "$CONTAINER/.gitignore" "$repo/.gitignore"; then
        for rel in .env .env.local app/.env.production docs/plans/issue-1.md; do
            (cd "$repo" && HOME="$repo/home" XDG_CONFIG_HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 git -c core.excludesFile= check-ignore -q -- "$rel") \
                || got="$got [not ignored: $rel]"
        done
        for rel in .env.example Dockerfile src/app.py; do
            (cd "$repo" && HOME="$repo/home" XDG_CONFIG_HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 git -c core.excludesFile= check-ignore -q -- "$rel") \
                && got="$got [ignored: $rel]"
        done
    else
        got=" [.gitignore missing]"
    fi
    rm -rf "$repo"
    if [ -z "$got" ]; then
        pass "container-ghcr: .gitignore ignores .env, .env.<name>, and docs/plans/, not .env.example"
    else
        fail "container-ghcr: .gitignore ignores .env, .env.<name>, and docs/plans/, not .env.example" "$got"
    fi
    # Docker reads .dockerignore with its own rules, so the check reads the
    # lines. "**/" also matches the root folder. A "!" line could put a
    # secret back, so none is allowed.
    got=""
    for rel in .git .github .claude docs/plans/ '**/.env' '**/.env.*'; do
        grep -qxF -- "$rel" "$CONTAINER/.dockerignore" 2>/dev/null || got="$got [no rule: $rel]"
    done
    f="$(grep -E '^[[:space:]]*!' "$CONTAINER/.dockerignore" 2>/dev/null | tr '\n' ' ')"
    [ -z "$f" ] || got="$got [negation: $f]"
    [ -f "$CONTAINER/.dockerignore" ] || got=" [.dockerignore missing]"
    if [ -z "$got" ]; then
        pass "container-ghcr: .dockerignore keeps git, CI, Claude, plans, and .env files out of the build"
    else
        fail "container-ghcr: .dockerignore keeps git, CI, Claude, plans, and .env files out of the build" "$got"
    fi
    check_whitespace container-ghcr "$CONTAINER" "$files"

    # 15. the container-ghcr manual steps
    got="$(awk '/^For `container-ghcr`:$/{p=1; next} p && (/^For / || /^## /){exit} p{print}' "$FAMILIES_DOC" 2>/dev/null | tr '\n' ' ')"
    rel=""
    for f in 'Dockerfile' 'Install Docker' 'pre-commit install' 'GHCR package' 'visibility' \
        'link the package to the repo' '`latest`' 'ci-workflows.md#host-pull-tag' \
        '`image / Lint (Dockerfile)`' '`image / Build`' '`App`' 'required_checks'; do
        printf '%s' "$got" | grep -qF -- "$f" || rel="$rel [$f]"
    done
    if [ -n "$got" ] && [ -z "$rel" ]; then
        pass "docs/families.md: the container-ghcr manual steps name the Dockerfile, Docker, GHCR visibility, the host pull tag, and the checks"
    else
        fail "docs/families.md: the container-ghcr manual steps name the Dockerfile, Docker, GHCR visibility, the host pull tag, and the checks" \
            "missing:${rel:- (no \"For \`container-ghcr\`:\" section)}"
    fi
}

check_family_b

# --- break-it controls -------------------------------------------------
# sub <file> <sed -E expression>: edit one file in place, portably.
sub() {
    sed -E -e "$2" "$1" > "$1.new" && mv "$1.new" "$1"
}
# fresh_copy <scratch-dir>: copy the inputs, and set T, D, S, P, CG.
fresh_copy() {
    SCR="$1"
    rm -rf "$SCR"; mkdir -p "$SCR"
    cp -R "$TEMPLATES_DIR" "$SCR/templates"
    cp "$FAMILIES_DOC" "$SCR/families.md"
    cp "$SETTINGS_TEMPLATE" "$SCR/settings.json"
    cp "$PIN_CHECK" "$SCR/check-action-pins.sh"
    T="$SCR/templates"; D="$SCR/families.md"; S="$SCR/settings.json"; P="$SCR/check-action-pins.sh"
    CG="$T/container-ghcr"
}
# run_on_copy: run this script on the copy. Output on stdout.
run_on_copy() {
    FAMILY_B_NO_CONTROLS=1 TEMPLATES_DIR="$T" BASELINE_DIR="$T/baseline" FAMILIES_DOC="$D" \
        SETTINGS_TEMPLATE="$S" FLOW_BIN="$FLOW_BIN" PIN_CHECK="$P" bash "$SELF" 2>&1
}
# The controls run in parallel. Each one writes its result to $RES/<n>.
RES="$TMPROOT/res"; mkdir -p "$RES"
NCTL=0
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
[ "$JOBS" -gt 8 ] && JOBS=8
[ "$JOBS" -lt 2 ] && JOBS=2
# control <name> <expected-failing-check> <mutation>
# <mutation> runs with T, D, S, P, CG set (all in a scratch copy). The script
# runs on the copy and must print "FAIL: <expected-failing-check>" and
# exit 1.
control() {
    local name="$1" expect="$2" mutation="$3" n
    NCTL=$((NCTL + 1)); n=$NCTL
    printf '%s\n%s\n' "$name" "$expect" > "$RES/$n.name"
    (
        local out rc
        fresh_copy "$TMPROOT/scratch-$n"
        eval "$mutation"
        out="$(run_on_copy)"; rc=$?
        if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF -- "FAIL: $expect"; then
            echo ok > "$RES/$n"
        else
            { echo "exit: $rc"; printf '%s\n' "$out" | grep -E '^(FAIL|[0-9]+ scenario)' | head -4; } > "$RES/$n"
        fi
        rm -rf "$TMPROOT/scratch-$n"
    ) &
    if [ $((n % JOBS)) -eq 0 ]; then wait; fi
}
# controls_report: wait for all controls, then print one result for each.
controls_report() {
    local i name expect
    wait
    i=1
    while [ "$i" -le "$NCTL" ]; do
        name="$(sed -n 1p "$RES/$i.name")"; expect="$(sed -n 2p "$RES/$i.name")"
        if [ "$(cat "$RES/$i" 2>/dev/null)" = ok ]; then
            pass "control $name: check failed as expected ($expect)"
        else
            fail "control $name: check did not fail as expected" "expected: FAIL: $expect" \
                "$(tr '\n' ' ' < "$RES/$i" 2>/dev/null)"
        fi
        i=$((i + 1))
    done
}

if [ "${FAMILY_B_NO_CONTROLS:-}" != "1" ]; then
    # The unbroken copy must pass, or every control proves nothing.
    fresh_copy "$TMPROOT/scratch-clean"
    out="$(run_on_copy)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "control clean-copy: the unbroken scratch copy passes"
    else
        fail "control clean-copy: the unbroken scratch copy passes" "exit: $rc" "$(printf '%s\n' "$out" | grep '^FAIL' | head -5)"
    fi

    # 1. file set
    control file-extra "container-ghcr: file set is exact" 'printf "FROM scratch\n" > "$CG/Dockerfile"'
    control file-missing "container-ghcr: file set is exact" 'rm "$CG/.dockerignore"'
    # 2. overrides and the docs table
    control override-workflow "container-ghcr: the overrides are the container-ghcr rows of the docs table" \
        'cp "$T/baseline/.github/workflows/claude.yml" "$CG/.github/workflows/claude.yml"'
    control override-row-missing "container-ghcr: the overrides are the container-ghcr rows of the docs table" \
        'sub "$D" "/^\| \`container-ghcr\` \| \`\.pre-commit-config\.yaml\` \|/d"'
    control override-row-extra "container-ghcr: the overrides are the container-ghcr rows of the docs table" \
        'sub "$D" "s/^(\| \`container-ghcr\` \| \`\.github\/dependabot\.yml\` \|.*)$/\1\n| \`container-ghcr\` | \`.github\/workflows\/claude.yml\` | x |/"'
    control override-rows-none "container-ghcr: the overrides are the container-ghcr rows of the docs table" \
        'sub "$D" "/^\| \`container-ghcr\` \| \`\./d"'
    # 3. parse
    control yaml-broken "container-ghcr: parses: .github/workflows/container-image.yml" \
        'printf "a: [1, 2\nb: : :\n" > "$CG/.github/workflows/container-image.yml"'
    control json-broken "container-ghcr: parses: .claude/settings.json" \
        'printf "{ \"a\": \n" > "$CG/.claude/settings.json"'
    # 4. override content
    control baseline-dependabot-changed "container-ghcr: dependabot override holds the baseline content" \
        'sub "$T/baseline/.github/dependabot.yml" "s/interval: weekly/interval: daily/"'
    control baseline-dependabot-comment "container-ghcr: dependabot override holds the baseline content" \
        'sub "$T/baseline/.github/dependabot.yml" "s/^# Baseline Dependabot/# Base Dependabot/"'
    control override-dependabot-drops-entry "container-ghcr: dependabot override holds the baseline content" \
        'sub "$CG/.github/dependabot.yml" "s/package-ecosystem: github-actions/package-ecosystem: pip/"'
    control baseline-precommit-rev "container-ghcr: pre-commit override holds the baseline content" \
        'sub "$T/baseline/.pre-commit-config.yaml" "s/rev: v8\.30\.1/rev: v8.30.2/"'
    control baseline-precommit-missing "container-ghcr: pre-commit override holds the baseline content" \
        'rm "$T/baseline/.pre-commit-config.yaml"'
    control override-precommit-drops-hook "container-ghcr: pre-commit override holds the baseline content" \
        'sub "$CG/.pre-commit-config.yaml" "/^      - id: check-json$/d"'
    # 5. YAML placeholder form
    control yaml-placeholder-unquoted "container-ghcr: each YAML placeholder is a full quoted value" \
        'sub "$CG/.github/dependabot.yml" "s/\"\{\{stack_ecosystem\}\}\"/{{stack_ecosystem}}/"'
    control yaml-placeholder-in-string "container-ghcr: each YAML placeholder is a full quoted value" \
        'sub "$CG/.github/workflows/ci.yml" "s/run: \"\{\{lint\}\}\"/run: \"make {{lint}}\"/"'
    control yaml-placeholder-comment "container-ghcr: each YAML placeholder is a full quoted value" \
        'printf "# The {{lint}} step runs the linter.\n" >> "$CG/.github/workflows/container-image.yml"'
    # 6. caller
    control caller-ref "container-ghcr: the caller job image uses container-image.yml@main" \
        'sub "$CG/.github/workflows/container-image.yml" "s/container-image\.yml@main/container-image.yml@v1.4.0/"'
    control caller-job-id "container-ghcr: the caller job image uses container-image.yml@main" \
        'sub "$CG/.github/workflows/container-image.yml" "s/^  image:$/  build:/"'
    control caller-no-packages "container-ghcr: the image job permissions are contents: read and packages: write" \
        'sub "$CG/.github/workflows/container-image.yml" "/^      packages: write$/d"'
    control caller-no-tags "container-ghcr: the caller runs on each PR, a push to main, and a strict vX.Y.Z tag" \
        'sub "$CG/.github/workflows/container-image.yml" "/^    tags:/d"'
    control caller-no-pr "container-ghcr: the caller runs on each PR, a push to main, and a strict vX.Y.Z tag" \
        'sub "$CG/.github/workflows/container-image.yml" "/^  pull_request:$/d"'
    control caller-branches "container-ghcr: the caller runs on each PR, a push to main, and a strict vX.Y.Z tag" \
        'sub "$CG/.github/workflows/container-image.yml" "s/branches: \[main\]/branches: [main, \"milestone\/**\"]/"'
    control caller-extra-trigger "container-ghcr: the caller runs on each PR, a push to main, and a strict vX.Y.Z tag" \
        'sub "$CG/.github/workflows/container-image.yml" "s/^  pull_request:$/  pull_request:\n  workflow_dispatch:/"'
    control caller-group-per-ref "container-ghcr: the caller puts all tag runs in one concurrency group, and cancels only a PR run" \
        'sub "$CG/.github/workflows/container-image.yml" "s/^  group: .*/  group: \${{ github.workflow }}-\${{ github.ref }}/"'
    control caller-cancel-always "container-ghcr: the caller puts all tag runs in one concurrency group, and cancels only a PR run" \
        'sub "$CG/.github/workflows/container-image.yml" "s/^  cancel-in-progress: .*/  cancel-in-progress: true/"'
    control caller-loose-tag-filter "container-ghcr: the caller runs on each PR, a push to main, and a strict vX.Y.Z tag" \
        'sub "$CG/.github/workflows/container-image.yml" "s/tags: \[.*\]$/tags: [\"v*.*.*\"]/"'
    control caller-with "container-ghcr: the caller has no with:, and a comment shows it" \
        'sub "$CG/.github/workflows/container-image.yml" "s/^    # with:$/    with:\n      platforms: linux\/amd64/"'
    # 7. ci.yml
    control ci-no-pull-request "container-ghcr: ci.yml runs on each pull_request, with no filter" \
        'sub "$CG/.github/workflows/ci.yml" "/^  pull_request:$/d"'
    control ci-push-branches "container-ghcr: ci.yml push branches are main and milestone/**" \
        'sub "$CG/.github/workflows/ci.yml" "s#\"milestone/\*\*\"#\"release/**\"#"'
    control ci-permissions "container-ghcr: ci.yml permissions are contents: read" \
        'sub "$CG/.github/workflows/ci.yml" "s/^  contents: read$/  contents: write/"'
    control ci-job-name "container-ghcr: ci.yml has the job app with the name App" \
        'sub "$CG/.github/workflows/ci.yml" "s/^    name: App$/    name: Build/"'
    control ci-no-test-step "container-ghcr: ci.yml App job runs {{lint}} and {{test}}" \
        'sub "$CG/.github/workflows/ci.yml" "s/run: \"\{\{test\}\}\"/run: \"{{lint}}\"/"'
    control ci-unpinned-action "container-ghcr: check-action-pins.sh passes on the workflows" \
        'sub "$CG/.github/workflows/ci.yml" "s#actions/checkout@[0-9a-f]+#actions/checkout@v7#"'
    # 8. Dependabot
    control dependabot-no-docker "container-ghcr: dependabot ecosystems are github-actions, docker, and {{stack_ecosystem}}" \
        'sub "$CG/.github/dependabot.yml" "s/package-ecosystem: docker/package-ecosystem: npm/"'
    control dependabot-stack-unquoted "container-ghcr: dependabot stack entry is the quoted \"{{stack_ecosystem}}\"" \
        'sub "$CG/.github/dependabot.yml" "s/\"\{\{stack_ecosystem\}\}\"/'"'"'{{stack_ecosystem}}'"'"'/"'
    control dependabot-prefix "container-ghcr: new dependabot entries are weekly, grouped, at /, with the baseline prefix" \
        'sub "$CG/.github/dependabot.yml" "/package-ecosystem: docker/,/prefix/ s/prefix: chore\(deps\)/prefix: build(deps)/"'
    control dependabot-daily "container-ghcr: new dependabot entries are weekly, grouped, at /, with the baseline prefix" \
        'sub "$CG/.github/dependabot.yml" "/stack_ecosystem/,\$ s/interval: weekly/interval: daily/"'
    control dependabot-no-group "container-ghcr: new dependabot entries are weekly, grouped, at /, with the baseline prefix" \
        'sub "$CG/.github/dependabot.yml" "/^      docker:$/,/^        patterns:/d"'
    # 9. pre-commit hooks
    control hadolint-upstream-repo "container-ghcr: pre-commit has no hadolint repo hook" \
        'sub "$CG/.pre-commit-config.yaml" "s/^  - repo: local$/  - repo: https:\/\/github.com\/hadolint\/hadolint\n    rev: v2.15.1\n    hooks:\n      - id: hadolint-docker\n  - repo: local/"'
    control hadolint-image-no-tag "container-ghcr: the local hadolint hook pins the image by tag and digest" \
        'sub "$CG/.pre-commit-config.yaml" "s#ghcr\.io/hadolint/hadolint:[^ ]+ hadolint#ghcr.io/hadolint/hadolint hadolint#"'
    control hadolint-image-latest "container-ghcr: the local hadolint hook pins the image by tag and digest" \
        'sub "$CG/.pre-commit-config.yaml" "s#hadolint:v[0-9.]+@#hadolint:latest@#"'
    control hadolint-image-no-digest "container-ghcr: the local hadolint hook pins the image by tag and digest" \
        'sub "$CG/.pre-commit-config.yaml" "s#@sha256:[0-9a-f]+ hadolint# hadolint#"'
    control hadolint-language "container-ghcr: the local hadolint hook pins the image by tag and digest" \
        'sub "$CG/.pre-commit-config.yaml" "s/language: docker_image/language: system/"'
    control hadolint-types "container-ghcr: the local hadolint hook pins the image by tag and digest" \
        'sub "$CG/.pre-commit-config.yaml" "s/types: \[dockerfile\]/types: [file]/"'
    control local-no-hadolint "container-ghcr: pre-commit local hooks are hadolint and test-quick" \
        'sub "$CG/.pre-commit-config.yaml" "s/- id: hadolint$/- id: lint-dockerfile/"'
    control local-test-quick-entry "container-ghcr: pre-commit local hooks are hadolint and test-quick" \
        'sub "$CG/.pre-commit-config.yaml" "s/- \"\{\{test_quick\}\}\"/- \"{{test}}\"/"'
    control local-no-shell "container-ghcr: pre-commit local hooks are hadolint and test-quick" \
        'sub "$CG/.pre-commit-config.yaml" "/^          - \"-c\"$/d"'
    control local-pass-filenames "container-ghcr: pre-commit local hooks are hadolint and test-quick" \
        'sub "$CG/.pre-commit-config.yaml" "\$ s/pass_filenames: false/pass_filenames: true/"'
    control local-commented-out "container-ghcr: pre-commit local hooks are hadolint and test-quick" \
        'sub "$CG/.pre-commit-config.yaml" "/^  - repo: local$/,\$ s/^/# /"'
    # 10. devkit pin rule
    control pin-not-main "pin rule: each devkit uses line in baseline and container-ghcr ends in @main" \
        'sub "$CG/.github/workflows/container-image.yml" "s#container-image\.yml@main#container-image.yml@v1.4.0#"'
    control pin-rewrite-other-action "pin rule: the Devkit pin rewrite passes check-action-pins.sh and leaves no @main" \
        'printf "  other:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/checkout@v4\n" >> "$CG/.github/workflows/container-image.yml"'
    # 11. project.md
    control project-md-unknown-key "container-ghcr: flow-project-check passes on project.md" \
        'printf -- "- bogus_key: \`x\`\n" >> "$CG/.claude/project.md"'
    control project-md-no-test-quick "container-ghcr: project.md has each needed key" \
        'sub "$CG/.claude/project.md" "/^- test_quick:/d"'
    # 12. settings.json
    control settings-allow-missing "container-ghcr: settings.json equals templates/settings.json" \
        'sub "$CG/.claude/settings.json" "/flow-repo:/d"'
    control settings-template-grew "container-ghcr: settings.json equals templates/settings.json" \
        'sub "$S" "s/\"Bash\(flow-repo:\*\)\",/\"Bash(flow-repo:*)\", \"Bash(flow-new:*)\",/"'
    # 13. CLAUDE.md
    control claude-block-edited "container-ghcr: CLAUDE.md flow block equals claude-block.md and the web-app block" \
        'sub "$CG/CLAUDE.md" "s/One PR for each/One PR per/"'
    control claude-block-web-app "container-ghcr: CLAUDE.md flow block equals claude-block.md and the web-app block" \
        'sub "$T/web-app/CLAUDE.md" "s/hotfix branches/hotfix starts/"'
    control claude-no-edge "container-ghcr: CLAUDE.md names the image tags and the hotfix patch tag" \
        'sub "$CG/CLAUDE.md" "s/\`edge\`/\`nightly\`/g"'
    control claude-no-patch-tag "container-ghcr: CLAUDE.md names the image tags and the hotfix patch tag" \
        'sub "$CG/CLAUDE.md" "s/patch tag/new tag/g"'
    # 14. placeholders, project facts, ignore files, whitespace
    control placeholder-unlisted-doc "container-ghcr: each placeholder is listed in docs/families.md" \
        'sub "$D" "s/\{\{stack_ecosystem\}\}/{{ecosystem}}/g"'
    control placeholder-unlisted-dotfile "container-ghcr: each placeholder is listed in docs/families.md" \
        'printf "# {{extra_key}}\n" >> "$CG/.dockerignore"'
    control project-fact-name "container-ghcr: no project name in a template file" \
        'printf "ElanRegistry\n" >> "$CG/CLAUDE.md"'
    control gitignore-env "container-ghcr: .gitignore ignores .env, .env.<name>, and docs/plans/, not .env.example" \
        'sub "$CG/.gitignore" "/^\.env$/d"'
    control gitignore-example "container-ghcr: .gitignore ignores .env, .env.<name>, and docs/plans/, not .env.example" \
        'sub "$CG/.gitignore" "/^!\.env\.example$/d"'
    control gitignore-plans "container-ghcr: .gitignore ignores .env, .env.<name>, and docs/plans/, not .env.example" \
        'sub "$CG/.gitignore" "/docs\/plans/d"'
    control dockerignore-env "container-ghcr: .dockerignore keeps git, CI, Claude, plans, and .env files out of the build" \
        'sub "$CG/.dockerignore" "/^\*\*\/\.env$/d"'
    control dockerignore-root-only "container-ghcr: .dockerignore keeps git, CI, Claude, plans, and .env files out of the build" \
        'sub "$CG/.dockerignore" "s/^\*\*\/\.env\.\*$/.env.*/"'
    control dockerignore-negation "container-ghcr: .dockerignore keeps git, CI, Claude, plans, and .env files out of the build" \
        'printf "!.env.production\n" >> "$CG/.dockerignore"'
    control dockerignore-git "container-ghcr: .dockerignore keeps git, CI, Claude, plans, and .env files out of the build" \
        'sub "$CG/.dockerignore" "/^\.git$/d"'
    control whitespace-trailing "container-ghcr: clean whitespace" \
        'printf "trailing \n" >> "$CG/.claude/rules/image-review.md"'
    control whitespace-dotfile "container-ghcr: clean whitespace" \
        'printf "\n" >> "$CG/.dockerignore"'
    # 15. manual steps
    control doc-no-visibility "docs/families.md: the container-ghcr manual steps name the Dockerfile, Docker, GHCR visibility, the host pull tag, and the checks" \
        'sub "$D" "/^For \`container-ghcr\`:$/,\$ s/package visibility/package access/"'
    control doc-no-docker "docs/families.md: the container-ghcr manual steps name the Dockerfile, Docker, GHCR visibility, the host pull tag, and the checks" \
        'sub "$D" "s/Install Docker on each/Install pre-commit on each/"'
    control doc-no-pull-tag "docs/families.md: the container-ghcr manual steps name the Dockerfile, Docker, GHCR visibility, the host pull tag, and the checks" \
        'sub "$D" "/^For \`container-ghcr\`:$/,\$ s/\`latest\`/the newest tag/"'
    control doc-no-build-check "docs/families.md: the container-ghcr manual steps name the Dockerfile, Docker, GHCR visibility, the host pull tag, and the checks" \
        'sub "$D" "/^For \`container-ghcr\`:$/,\$ s/\`image \/ Build\`/\`image\`/"'
    control doc-no-section "docs/families.md: the container-ghcr manual steps name the Dockerfile, Docker, GHCR visibility, the host pull tag, and the checks" \
        'sub "$D" "s/^For \`container-ghcr\`:$/For the image repo:/"'
    controls_report
fi

harness_report
