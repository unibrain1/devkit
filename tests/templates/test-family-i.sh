#!/bin/bash
#
# Tests for the Family I template: plugins/flow/templates/ios-app/ (the
# files of a new iOS app repo, at the paths that the target repo uses).
#
# Checks: the exact file set (and no workflows folder), the baseline paths
# that ios-app overrides (the allowed set comes from the override table in
# docs/families.md), the override content (every baseline entry and line,
# and the pre-commit override must add exactly default_install_hook_types),
# the local swiftlint hook (commit), the xcodebuild-test hook (pre-push),
# the .swiftlint.yml excluded paths, project.md and flow-project-check, no
# macOS CI, the Dependabot ecosystems, CLAUDE.md, YAML and JSON validity and
# the YAML placeholder form, the placeholders and the deny list,
# settings.json against templates/settings.json, the .gitignore effect (git
# check-ignore), whitespace, and the ios-app manual steps.
#
# Override check: it is semantic, as in test-family-b.sh. Every entry of the
# baseline file must be present, equal, in the parsed override, and the
# other top-level keys must be equal, except the one extra key that
# docs/families.md allows. The pre-commit override must add that key. A
# second check requires every line of the baseline file, comments too, in
# the override.
#
# YAML placeholder check: comments count too. After the ${{ ... }} GitHub
# expressions are removed, each line that holds "{{" must be one key with
# the quoted value "{{key}}" and nothing more.
#
# Each check has a break-it control. The control copies the inputs to a
# scratch folder, breaks one thing, runs this script on the copy, and
# expects the named check to fail. Set FAMILY_I_NO_CONTROLS=1 to skip them.
#
# Env overrides, for the controls on scratch copies:
#   TEMPLATES_DIR      the templates folder: baseline/, ios-app/, claude-block.md
#   BASELINE_DIR       the baseline folder (default: $TEMPLATES_DIR/baseline)
#   FAMILIES_DOC       docs/families.md
#   SETTINGS_TEMPLATE  templates/settings.json
#   FLOW_BIN           the folder with flow-project-check and flow-project-fact
#
# Usage: bash tests/templates/test-family-i.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# SC2016: the control mutations are single-quoted on purpose. eval expands
# them inside the control. SC2034: eval reads IA. SC2155: a local that holds
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
CLAUDE_BLOCK="$TEMPLATES_DIR/claude-block.md"
IOS="$TEMPLATES_DIR/ios-app"

TMPROOT="$(mktemp -d)" || exit 1

# Names that must not appear in a template: they are project facts. The
# match is case-sensitive.
DENY_LIST="MyGunLog ElanRegistry Registry TeamCroc BurgessMachineWorks BurgessGunWorks devkit-sandbox DryFireTimer Dryfire"

# The only placeholders that ios-app may hold.
ALLOWED_PLACEHOLDERS="{{app_name}} {{app_description}} {{test}}"

# The extra top-level key that the ios-app pre-commit override must add.
EXTRA_KEY="default_install_hook_types"

# Check labels. The controls name the check that must fail.
L_FILES="ios-app: file set is exact, with no workflows folder"
L_TABLE="ios-app: the overrides are the ios-app rows of the docs table"
L_DEP_HOLD="ios-app: dependabot override holds the baseline content"
L_PC_HOLD="ios-app: pre-commit override holds the baseline content, plus only default_install_hook_types"
L_PLACE_FORM="ios-app: each YAML placeholder is a full quoted value"
L_SWIFTLINT="ios-app: the local swiftlint hook runs swiftlint lint --strict --force-exclude at commit"
L_SWIFTLINT_CFG="ios-app: .swiftlint.yml excludes DerivedData, build, and .build"
L_XCODE="ios-app: the local xcodebuild-test hook runs bash -c {{test}} at each pre-push"
L_INSTALL="ios-app: default_install_hook_types is pre-commit and pre-push"
L_PM_CHECK="ios-app: flow-project-check passes on project.md"
L_PM_FACTS="ios-app: project.md test equals the hook command, and lint is swiftlint lint --strict"
L_DOC_FORM="docs/families.md: shows the xcodebuild test form"
L_NO_MAC="ios-app: no file holds runs-on or macos"
L_DEP_ECO="ios-app: dependabot ecosystems are github-actions and swift"
L_DEP_SWIFT="ios-app: the swift dependabot entry is at / and weekly"
L_CLAUDE_BREW="ios-app: CLAUDE.md names brew install swiftlint"
L_CLAUDE_DEPLOY="ios-app: CLAUDE.md has a Deployment section that names Xcode and sideload"
L_CLAUDE_BLOCK="ios-app: CLAUDE.md flow block equals claude-block.md"
L_CLAUDE_TABLE="ios-app: the CLAUDE.md command table names {{test}} and swiftlint lint --strict"
L_PLACE_SET="ios-app: only the placeholders app_name, app_description, and test appear"
L_PLACE_DOC="ios-app: each placeholder is listed in docs/families.md"
L_DENY="ios-app: no project name in a template file"
L_SETTINGS="ios-app: settings.json is templates/settings.json plus the Swift rules"
L_IGN_YES="ios-app: .gitignore ignores Xcode output, signing files, .env files, and docs/plans/"
L_IGN_NO="ios-app: .gitignore keeps .env.example, Package.resolved, and Swift sources"
L_WS="ios-app: clean whitespace"
L_MANUAL="docs/families.md: the ios-app manual steps name brew install swiftlint, pre-commit install, and the swift entry"

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
# the cache that the ruby call below fills.
YJ="$TMPROOT/yj"; mkdir -p "$YJ"
# shellcheck disable=SC2046 # the file names hold no space
ruby "$TMPROOT/y2j.rb" "$YJ" $(find "$IOS" "$BASELINE_DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort -u) 2>/dev/null
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

# doc_overrides: the Override paths of the ios-app rows in the override
# table of docs/families.md, one on each line, sorted.
doc_overrides() {
    sed -nE 's/^\| `ios-app` \| `([^`]+)` \|.*/\1/p' "$FAMILIES_DOC" 2>/dev/null | LC_ALL=C sort -u
}

# override_holds_baseline <rel> <list key> <entry label key> <extra keys>:
# prints each problem. The baseline file and the override must have equal
# top-level keys except <list key> and the <extra keys> (a JSON array,
# sorted). The override may add exactly the <extra keys>. Each baseline
# <list key> entry must be in the override. Each line of the baseline file
# must be in the override.
override_holds_baseline() {
    local rel="$1" key="$2" label="$3" extra="$4" base over
    base="$(y2j "$BASELINE_DIR/$rel")"
    over="$(y2j "$IOS/$rel")"
    if [ -z "$base" ]; then
        echo "baseline $rel is missing or does not parse"
        return
    fi
    printf '%s' "$base" | jq -r --argjson f "${over:-null}" --arg k "$key" --arg l "$label" --argjson x "$extra" '
        . as $b
        | [ (if ($b | del(.[$k])) == (($f // {}) | del(.[$k]) | del(.[$x[]])) then empty else "top-level keys" end),
            (if ((($f // {}) | keys) - ($b | keys)) == $x then empty else "extra top-level keys" end),
            ($b[$k][] | . as $e
                | select(any((($f // {})[$k] // [])[]; . == $e) | not)
                | $k + " " + (.[$l] | tostring)) ] | join(", ")' 2>&1
    grep -vxFf "$IOS/$rel" "$BASELINE_DIR/$rel" 2>/dev/null | sed 's/^/ line missing: /' | tr '\n' ' '
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
        pass "$label"
    else
        fail "$label" "problems:${got:- (no files)}"
    fi
}

# ignore_check <repo> <expect: yes|no> <path>...: prints each path whose
# git check-ignore result is not the expected one. The empty
# core.excludesFile and the scratch XDG_CONFIG_HOME keep the user's global
# ignore file out.
ignore_check() {
    local repo="$1" want="$2" p rc; shift 2
    for p in "$@"; do
        (cd "$repo" && HOME="$repo/home" XDG_CONFIG_HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 \
            git -c core.excludesFile= check-ignore -q -- "$p"); rc=$?
        # Exit 1 means "not ignored". A higher exit is a git error, not a result.
        if [ "$rc" -gt 1 ]; then printf ' [git error %s: %s]' "$rc" "$p"; continue; fi
        if [ "$want" = yes ] && [ "$rc" -ne 0 ]; then printf ' [not ignored: %s]' "$p"; fi
        if [ "$want" = no ] && [ "$rc" -eq 0 ]; then printf ' [ignored: %s]' "$p"; fi
    done
}

check_family_i() {
    local want got f rel rc files base_files allowed pcj depj repo kept

    files="$(files_in "$IOS")"
    base_files="$(files_in "$BASELINE_DIR")"

    # 1. exact file set, and no workflows folder
    want=".claude/project.md
.claude/rules/ios-review.md
.claude/settings.json
.github/dependabot.yml
.gitignore
.pre-commit-config.yaml
.swiftlint.yml
CLAUDE.md"
    if [ "$files" = "$want" ] && [ ! -e "$IOS/.github/workflows" ]; then
        pass "$L_FILES"
    else
        fail "$L_FILES" "got: $(printf '%s' "$files" | tr '\n' ' ')"
    fi

    # 2. the overrides are the ios-app rows of the docs table
    allowed="$(doc_overrides)"
    got=""
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        if [ -e "$IOS/$rel" ] && ! printf '%s\n' "$allowed" | grep -qFx -- "$rel"; then
            got="$got [not in the table: $rel]"
        fi
    done <<EOF
$base_files
EOF
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        printf '%s\n' "$base_files" | grep -qFx -- "$rel" || got="$got [not a baseline path: $rel]"
        [ -e "$IOS/$rel" ] || got="$got [no file: $rel]"
    done <<EOF
$allowed
EOF
    if [ -z "$got" ] && [ -n "$allowed" ] && [ -n "$base_files" ]; then
        pass "$L_TABLE"
    else
        fail "$L_TABLE" "problems:${got:- (no ios-app rows, or baseline folder empty)}"
    fi

    # 3. each YAML and JSON file parses
    pcj="{}"; depj="{}"
    while IFS= read -r rel; do
        case "$rel" in
            *.yml|*.yaml) ;;
            *) continue ;;
        esac
        if f="$(y2j "$IOS/$rel")"; then
            pass "ios-app: parses: $rel"
            case "$rel" in
                .pre-commit-config.yaml) pcj="$f" ;;
                .github/dependabot.yml) depj="$f" ;;
            esac
        else
            fail "ios-app: parses: $rel"
        fi
    done <<EOF
$files
EOF
    if jq empty "$IOS/.claude/settings.json" >/dev/null 2>&1; then
        pass "ios-app: parses: .claude/settings.json"
    else
        fail "ios-app: parses: .claude/settings.json"
    fi

    # 4. each override holds the baseline content
    got="$(override_holds_baseline .github/dependabot.yml updates package-ecosystem '[]')"
    if [ -z "$got" ]; then
        pass "$L_DEP_HOLD"
    else
        fail "$L_DEP_HOLD" "$got"
    fi
    got="$(override_holds_baseline .pre-commit-config.yaml repos repo "[\"$EXTRA_KEY\"]")"
    if [ -z "$got" ]; then
        pass "$L_PC_HOLD"
    else
        fail "$L_PC_HOLD" "$got"
    fi

    # 5. YAML placeholders are full quoted values
    got=""
    while IFS= read -r rel; do
        case "$rel" in
            *.yml|*.yaml) ;;
            *) continue ;;
        esac
        f="$(strip_gha "$IOS/$rel" | grep -F '{{' \
            | grep -vE '^[[:space:]]*(-[[:space:]]+)?([A-Za-z0-9_-]+:[[:space:]]+)?"\{\{[a-z_]+\}\}"[[:space:]]*$')"
        [ -z "$f" ] || got="$got [$rel: $(printf '%s' "$f" | tr '\n' '|')]"
    done <<EOF
$files
EOF
    if [ -z "$got" ]; then
        pass "$L_PLACE_FORM"
    else
        fail "$L_PLACE_FORM" "bad:$got"
    fi

    # 6. swiftlint at commit
    got="$(printf '%s' "$pcj" | jq -r '
        [.repos[]? | select(.repo == "local") | .hooks[]? | select(.id == "swiftlint")] as $h
        | if ($h | length) != 1 then "swiftlint hooks: \($h | length)"
          elif $h[0].entry != "swiftlint lint --strict --force-exclude" then "entry: \($h[0].entry)"
          elif $h[0].language != "system" then "language: \($h[0].language)"
          elif ($h[0].types | type) != "array" or (($h[0].types | index("swift")) == null) then "types: \($h[0].types)"
          elif ($h[0] | has("types_or") or has("files") or has("exclude")) then "file filter: \($h[0] | {types_or, files, exclude})"
          elif $h[0].stages != ["pre-commit"] then "stages: \($h[0].stages)"
          else empty end' 2>&1)"
    if [ -z "$got" ]; then
        pass "$L_SWIFTLINT"
    else
        fail "$L_SWIFTLINT" "$got"
    fi
    # The lint key lints the whole tree, so it needs the excluded paths.
    got="$( { y2j "$IOS/.swiftlint.yml" 2>/dev/null || echo '{}'; } | jq -r '
        (.excluded // []) as $x
        | if ($x | type) != "array" then "excluded is not a list: \($x)"
          else ["DerivedData", "build", ".build"] - $x | join(" ") end' 2>&1)"
    if [ -z "$got" ] && [ -f "$IOS/.swiftlint.yml" ]; then
        pass "$L_SWIFTLINT_CFG"
    else
        fail "$L_SWIFTLINT_CFG" "not excluded: ${got:- (no .swiftlint.yml)}"
    fi

    # 7. xcodebuild test at pre-push
    got="$(printf '%s' "$pcj" | jq -r '
        [.repos[]? | select(.repo == "local") | .hooks[]? | select(.id == "xcodebuild-test")] as $h
        | if ($h | length) != 1 then "xcodebuild-test hooks: \($h | length)"
          elif $h[0].entry != "bash" then "entry: \($h[0].entry)"
          elif $h[0].args != ["-c", "{{test}}"] then "args: \($h[0].args)"
          elif $h[0].language != "system" then "language: \($h[0].language)"
          elif $h[0].pass_filenames != false then "pass_filenames: \($h[0].pass_filenames)"
          elif $h[0].always_run != true then "always_run: \($h[0].always_run)"
          elif ($h[0] | has("types") or has("types_or") or has("files") or has("exclude")) then "file filter: \($h[0] | {types, types_or, files, exclude})"
          elif $h[0].stages != ["pre-push"] then "stages: \($h[0].stages)"
          else empty end' 2>&1)"
    if [ -z "$got" ]; then
        pass "$L_XCODE"
    else
        fail "$L_XCODE" "$got"
    fi
    got="$(printf '%s' "$pcj" | jq -c '.default_install_hook_types')"
    if [ "$got" = '["pre-commit","pre-push"]' ]; then
        pass "$L_INSTALL"
    else
        fail "$L_INSTALL" "got: $got"
    fi

    # 8. project.md
    repo="$TMPROOT/pc"
    scratch_git "$repo"
    mkdir -p "$repo/.claude"
    cp "$IOS/.claude/project.md" "$repo/.claude/project.md" 2>/dev/null
    got="$(cd "$repo" && "$FLOW_BIN/flow-project-check" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$L_PM_CHECK"
    else
        fail "$L_PM_CHECK" "exit: $rc" "$got"
    fi
    got=""
    local fact hook_arg
    fact="$(cd "$repo" && "$FLOW_BIN/flow-project-fact" test 2>/dev/null)"
    hook_arg="$(printf '%s' "$pcj" | jq -r '[.repos[]? | select(.repo == "local") | .hooks[]? | select(.id == "xcodebuild-test") | .args[1]] | .[0] // ""')"
    { [ "$fact" = "{{test}}" ] && [ "$fact" = "$hook_arg" ]; } || got="$got [test: '$fact', hook arg: '$hook_arg']"
    fact="$(cd "$repo" && "$FLOW_BIN/flow-project-fact" lint 2>/dev/null)"
    [ "$fact" = "swiftlint lint --strict" ] || got="$got [lint: '$fact']"
    if [ -z "$got" ]; then
        pass "$L_PM_FACTS"
    else
        fail "$L_PM_FACTS" "bad:$got"
    fi
    if grep -qF 'xcodebuild test -project' "$FAMILIES_DOC" 2>/dev/null \
        && grep -qF -- '-destination "platform=iOS Simulator' "$FAMILIES_DOC" 2>/dev/null; then
        pass "$L_DOC_FORM"
    else
        fail "$L_DOC_FORM"
    fi

    # 9. no macOS CI. The match is case-sensitive: the CLAUDE.md prose and the
    # .gitignore comment say "macOS".
    got="$(grep -rlE 'runs-on|macos' "$IOS" 2>/dev/null | tr '\n' ' ')"
    if [ -z "$got" ] && [ -d "$IOS" ]; then
        pass "$L_NO_MAC"
    else
        fail "$L_NO_MAC" "found in: ${got:- (no ios-app folder)}"
    fi

    # 10. Dependabot entries
    got="$(printf '%s' "$depj" | jq -r '[.updates[]?["package-ecosystem"]] | sort | join(" ")' 2>&1)"
    if [ "$got" = 'github-actions swift' ]; then
        pass "$L_DEP_ECO"
    else
        fail "$L_DEP_ECO" "got: $got"
    fi
    got="$(printf '%s' "$depj" | jq -r '
        [.updates[]? | select(.["package-ecosystem"] == "swift")] as $s
        | if ($s | length) != 1 then "swift entries: \($s | length)"
          elif $s[0].directory != "/" then "directory: \($s[0].directory)"
          elif $s[0].schedule.interval != "weekly" then "interval: \($s[0].schedule.interval)"
          else empty end' 2>&1)"
    if [ -z "$got" ]; then
        pass "$L_DEP_SWIFT"
    else
        fail "$L_DEP_SWIFT" "$got"
    fi

    # 11. CLAUDE.md
    if grep -qF 'brew install swiftlint' "$IOS/CLAUDE.md" 2>/dev/null; then
        pass "$L_CLAUDE_BREW"
    else
        fail "$L_CLAUDE_BREW"
    fi
    got="$(awk '/^## Deployment$/{p=1; next} p && /^## /{exit} p{print}' "$IOS/CLAUDE.md" 2>/dev/null)"
    if [ -n "$got" ] && printf '%s' "$got" | grep -qF 'Xcode' && printf '%s' "$got" | grep -qiF 'sideload'; then
        pass "$L_CLAUDE_DEPLOY"
    else
        fail "$L_CLAUDE_DEPLOY" "section: ${got:-(none)}"
    fi
    got="$(flow_block "$IOS/CLAUDE.md")"
    if [ -n "$got" ] && [ "$got" = "$(cat "$CLAUDE_BLOCK" 2>/dev/null)" ] \
        && [ "$(grep -c '^<!-- flow:begin' "$IOS/CLAUDE.md")" = "1" ]; then
        pass "$L_CLAUDE_BLOCK"
    else
        fail "$L_CLAUDE_BLOCK"
    fi
    if grep -E '^\|' "$IOS/CLAUDE.md" 2>/dev/null | grep -qF '`{{test}}`' \
        && grep -E '^\|' "$IOS/CLAUDE.md" 2>/dev/null | grep -qF '`swiftlint lint --strict`'; then
        pass "$L_CLAUDE_TABLE"
    else
        fail "$L_CLAUDE_TABLE"
    fi

    # 12. placeholders and project facts
    # One scan of each file feeds both placeholder checks.
    local unexpected="" unlisted="" ph
    while IFS= read -r f; do
        [ -f "$IOS/$f" ] || continue
        for ph in $(strip_gha "$IOS/$f" | grep -oE '\{\{[a-z_]+\}\}' | sort -u); do
            case " $ALLOWED_PLACEHOLDERS " in
                *" $ph "*) ;;
                *) unexpected="$unexpected $ph($f)" ;;
            esac
            grep -qF -- "\`$ph\`" "$FAMILIES_DOC" 2>/dev/null || unlisted="$unlisted $ph($f)"
        done
    done <<EOF
$files
EOF
    if [ -z "$unexpected" ]; then
        pass "$L_PLACE_SET"
    else
        fail "$L_PLACE_SET" "unexpected:$unexpected"
    fi
    got="$unlisted"
    if [ -z "$got" ] && [ -f "$FAMILIES_DOC" ]; then
        pass "$L_PLACE_DOC"
    else
        fail "$L_PLACE_DOC" "not listed:${got:- (families.md missing)}"
    fi
    got=""
    for rel in $DENY_LIST; do
        f="$(grep -rlF -e "$rel" "$IOS" 2>/dev/null | tr '\n' ' ')"
        [ -z "$f" ] || got="$got [$rel: $f]"
    done
    if [ -z "$got" ]; then
        pass "$L_DENY"
    else
        fail "$L_DENY" "found:$got"
    fi

    # 13. settings.json: the template plus the Swift rules. The arrays are
    # sorted, so only the set of rules counts.
    got="$(jq -S '.permissions.allow |= sort | .permissions.deny |= sort' "$IOS/.claude/settings.json" 2>/dev/null)"
    want="$(jq -S '
        .permissions.allow += ["Bash(swiftlint lint:*)", "Bash(xcodebuild test:*)"]
        | .permissions.deny += ["Read(./DerivedData/**)", "Edit(./DerivedData/**)",
                                "Read(./build/**)", "Edit(./build/**)",
                                "Read(./.build/**)", "Edit(./.build/**)"]
        | .permissions.allow |= sort | .permissions.deny |= sort' "$SETTINGS_TEMPLATE" 2>/dev/null)"
    if [ -n "$got" ] && [ "$got" = "$want" ]; then
        pass "$L_SETTINGS"
    else
        fail "$L_SETTINGS"
    fi

    # 14. .gitignore: git check-ignore tests the effect of the rules, so a
    # reorder or a later "!" rule that commits a secret fails too.
    repo="$TMPROOT/gitignore-$$"
    if scratch_git "$repo" && [ -f "$IOS/.gitignore" ] && cp "$IOS/.gitignore" "$repo/.gitignore"; then
        got="$(ignore_check "$repo" yes DerivedData/x build/x a/xcuserdata/x x.xcuserstate .build/x a.p12 a.cer \
            a.mobileprovision a.provisionprofile .swiftpm/x .env .env.local docs/plans/x.md .DS_Store)"
        kept="$(ignore_check "$repo" no .env.example \
            App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved App/ContentView.swift \
            App.xcodeproj/project.pbxproj App.xcodeproj/xcshareddata/xcschemes/App.xcscheme)"
    else
        got=" [.gitignore missing]"; kept=" [.gitignore missing]"
    fi
    rm -rf "$repo"
    if [ -z "$got" ]; then
        pass "$L_IGN_YES"
    else
        fail "$L_IGN_YES" "$got"
    fi
    if [ -z "$kept" ]; then
        pass "$L_IGN_NO"
    else
        fail "$L_IGN_NO" "$kept"
    fi

    # 15. whitespace
    check_whitespace "$L_WS" "$IOS" "$files"

    # 16. the ios-app manual steps
    got="$(awk '/^For `ios-app`:$/{p=1; next} p && (/^For / || /^## /){exit} p{print}' "$FAMILIES_DOC" 2>/dev/null | tr '\n' ' ')"
    rel=""
    for f in 'brew install swiftlint' 'pre-commit install' '`swift`' 'Dependabot'; do
        printf '%s' "$got" | grep -qF -- "$f" || rel="$rel [$f]"
    done
    if [ -n "$got" ] && [ -z "$rel" ]; then
        pass "$L_MANUAL"
    else
        fail "$L_MANUAL" "missing:${rel:- (no \"For \`ios-app\`:\" section)}"
    fi
}

check_family_i

# --- break-it controls -------------------------------------------------
# sub <file> <sed -E expression>: edit one file in place, portably.
sub() {
    sed -E -e "$2" "$1" > "$1.new" && mv "$1.new" "$1"
}
# fresh_copy <scratch-dir>: copy the inputs, and set T, D, S, IA.
fresh_copy() {
    SCR="$1"
    rm -rf "$SCR"; mkdir -p "$SCR"
    cp -R "$TEMPLATES_DIR" "$SCR/templates"
    cp "$FAMILIES_DOC" "$SCR/families.md"
    cp "$SETTINGS_TEMPLATE" "$SCR/settings.json"
    T="$SCR/templates"; D="$SCR/families.md"; S="$SCR/settings.json"
    IA="$T/ios-app"
}
# run_on_copy: run this script on the copy. Output on stdout.
run_on_copy() {
    FAMILY_I_NO_CONTROLS=1 TEMPLATES_DIR="$T" BASELINE_DIR="$T/baseline" FAMILIES_DOC="$D" \
        SETTINGS_TEMPLATE="$S" FLOW_BIN="$FLOW_BIN" bash "$SELF" 2>&1
}
# The controls run in parallel. Each one writes its result to $RES/<n>.
RES="$TMPROOT/res"; mkdir -p "$RES"
NCTL=0
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
[ "$JOBS" -gt 8 ] && JOBS=8
[ "$JOBS" -lt 2 ] && JOBS=2
# control <name> <expected-failing-check> <mutation>
# <mutation> runs with T, D, S, IA set (all in a scratch copy). The script
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

if [ "${FAMILY_I_NO_CONTROLS:-}" != "1" ]; then
    # The unbroken copy must pass, or every control proves nothing.
    fresh_copy "$TMPROOT/scratch-clean"
    out="$(run_on_copy)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "control clean-copy: the unbroken scratch copy passes"
    else
        fail "control clean-copy: the unbroken scratch copy passes" "exit: $rc" "$(printf '%s\n' "$out" | grep '^FAIL' | head -5)"
    fi

    # Paths in the mutations. The mutation strings are single-quoted, so
    # they hold the text $IA, and eval expands it inside the control.
    PC='$IA/.pre-commit-config.yaml'
    DEP='$IA/.github/dependabot.yml'
    GI='$IA/.gitignore'

    # 1. file set
    control file-extra "$L_FILES" 'printf "// x\n" > "$IA/Package.swift"'
    control file-missing "$L_FILES" 'rm "$IA/.swiftlint.yml"'
    control file-workflows "$L_FILES" 'mkdir -p "$IA/.github/workflows"; cp "$T/baseline/.github/workflows/claude.yml" "$IA/.github/workflows/claude.yml"'
    # 2. overrides and the docs table
    control override-workflow "$L_TABLE" 'mkdir -p "$IA/.github/workflows"; cp "$T/baseline/.github/workflows/claude.yml" "$IA/.github/workflows/claude.yml"'
    control override-row-missing "$L_TABLE" 'sub "$D" "/^\| \`ios-app\` \| \`\.pre-commit-config\.yaml\` \|/d"'
    control override-row-extra "$L_TABLE" \
        'printf "| \`ios-app\` | \`.github/workflows/claude.yml\` | x |\n" >> "$D"'
    control override-rows-none "$L_TABLE" 'sub "$D" "/^\| \`ios-app\` \| \`\./d"'
    # 3. parse
    control yaml-broken "ios-app: parses: .swiftlint.yml" 'printf "a: [1, 2\nb: : :\n" > "$IA/.swiftlint.yml"'
    control json-broken "ios-app: parses: .claude/settings.json" 'printf "{ \"a\": \n" > "$IA/.claude/settings.json"'
    # 4. override content
    control baseline-dependabot-changed "$L_DEP_HOLD" 'sub "$T/baseline/.github/dependabot.yml" "s/interval: weekly/interval: daily/"'
    control baseline-dependabot-comment "$L_DEP_HOLD" 'sub "$T/baseline/.github/dependabot.yml" "s/^# Baseline Dependabot/# Base Dependabot/"'
    control override-dependabot-drops-entry "$L_DEP_HOLD" 'sub "'"$DEP"'" "s/package-ecosystem: github-actions/package-ecosystem: pip/"'
    control override-dependabot-extra-key "$L_DEP_HOLD" 'printf "registries: {}\n" >> "'"$DEP"'"'
    control baseline-precommit-rev "$L_PC_HOLD" 'sub "$T/baseline/.pre-commit-config.yaml" "s/rev: v8\.30\.1/rev: v8.30.2/"'
    control baseline-precommit-missing "$L_PC_HOLD" 'rm "$T/baseline/.pre-commit-config.yaml"'
    control override-precommit-drops-hook "$L_PC_HOLD" 'sub "'"$PC"'" "/^      - id: check-json$/d"'
    control override-precommit-extra-key "$L_PC_HOLD" 'printf "fail_fast: true\n" >> "'"$PC"'"'
    control override-precommit-no-install-key "$L_PC_HOLD" 'sub "'"$PC"'" "/^default_install_hook_types:/d"'
    # 5. YAML placeholder form
    control yaml-placeholder-unquoted "$L_PLACE_FORM" 'sub "'"$PC"'" "s/\"\{\{test\}\}\"/{{test}}/"'
    control yaml-placeholder-in-string "$L_PLACE_FORM" 'sub "'"$PC"'" "s/\"\{\{test\}\}\"/\"make {{test}}\"/"'
    control yaml-placeholder-comment "$L_PLACE_FORM" 'printf "# The {{test}} step runs the tests.\n" >> "$IA/.swiftlint.yml"'
    # 6. swiftlint hook
    control swiftlint-entry "$L_SWIFTLINT" 'sub "'"$PC"'" "s/entry: swiftlint lint --strict/entry: swiftformat ./"'
    control swiftlint-language "$L_SWIFTLINT" 'sub "'"$PC"'" "/id: swiftlint\$/,/types:/ s/language: system/language: swift/"'
    control swiftlint-types "$L_SWIFTLINT" 'sub "'"$PC"'" "s/types: \[swift\]/types: [file]/"'
    control swiftlint-stages "$L_SWIFTLINT" 'sub "'"$PC"'" "/id: swiftlint\$/,/stages:/ s/stages: \[pre-commit\]/stages: [pre-commit, pre-push]/"'
    control swiftlint-no-stages "$L_SWIFTLINT" 'sub "'"$PC"'" "/^        stages: \[pre-commit\]\$/d"'
    control swiftlint-exclude "$L_SWIFTLINT" 'sub "'"$PC"'" "s/^        types: \[swift\]\$/        types: [swift]\n        exclude: \".*\"/"'
    control swiftlint-no-strict "$L_SWIFTLINT" 'sub "'"$PC"'" "s/entry: swiftlint lint --strict --force-exclude/entry: swiftlint lint --force-exclude/"'
    control swiftlint-no-force-exclude "$L_SWIFTLINT" 'sub "'"$PC"'" "s/entry: swiftlint lint --strict --force-exclude/entry: swiftlint lint --strict/"'
    control swiftlint-cfg-derived "$L_SWIFTLINT_CFG" 'sub "$IA/.swiftlint.yml" "/^  - DerivedData\$/d"'
    control swiftlint-cfg-spm "$L_SWIFTLINT_CFG" 'sub "$IA/.swiftlint.yml" "/^  - \.build\$/d"'
    control swiftlint-cfg-string "$L_SWIFTLINT_CFG" 'printf "excluded: DerivedData build .build\n" > "$IA/.swiftlint.yml"'
    control swiftlint-cfg-missing "$L_SWIFTLINT_CFG" 'printf "disabled_rules: [line_length]\n" > "$IA/.swiftlint.yml"'
    control swiftlint-missing "$L_SWIFTLINT" 'sub "'"$PC"'" "s/- id: swiftlint\$/- id: lint-swift/"'
    # 7. xcodebuild hook
    control xcode-entry "$L_XCODE" 'sub "'"$PC"'" "s/^        entry: bash\$/        entry: sh/"'
    control xcode-args-flag "$L_XCODE" 'sub "'"$PC"'" "s/^          - \"-c\"\$/          - \"-lc\"/"'
    control xcode-args-command "$L_XCODE" 'sub "'"$PC"'" "s/\"\{\{test\}\}\"/\"{{test_quick}}\"/"'
    control xcode-pass-filenames "$L_XCODE" 'sub "'"$PC"'" "s/^        pass_filenames: false\$/        pass_filenames: true/"'
    control xcode-language "$L_XCODE" 'sub "'"$PC"'" "/id: xcodebuild-test\$/,/stages:/ s/language: system/language: script/"'
    control xcode-always-run "$L_XCODE" 'sub "'"$PC"'" "/^        always_run: true\$/d"'
    control xcode-types "$L_XCODE" 'sub "'"$PC"'" "s/^        always_run: true\$/        always_run: true\n        types: [markdown]/"'
    control xcode-stages "$L_XCODE" 'sub "'"$PC"'" "s/^        stages: \[pre-push\]\$/        stages: [pre-commit]/"'
    control xcode-missing "$L_XCODE" 'sub "'"$PC"'" "s/- id: xcodebuild-test\$/- id: tests/"'
    control install-types "$L_INSTALL" 'sub "'"$PC"'" "s/^default_install_hook_types: .*/default_install_hook_types: [pre-commit]/"'
    # 8. project.md
    control project-md-unknown-key "$L_PM_CHECK" 'printf -- "- bogus_key: \`x\`\n" >> "$IA/.claude/project.md"'
    control project-md-test-differs "$L_PM_FACTS" 'sub "$IA/.claude/project.md" "s/^- test: .*/- test: \`make test\`/"'
    control project-md-lint "$L_PM_FACTS" 'sub "$IA/.claude/project.md" "s/swiftlint lint --strict/swiftlint lint/"'
    control doc-form-project "$L_DOC_FORM" 'sub "$D" "s/xcodebuild test -project/xcodebuild build -project/"'
    control doc-form-destination "$L_DOC_FORM" 'sub "$D" "s/platform=iOS Simulator/platform=macOS/"'
    # 9. no macOS CI
    control macos-runs-on "$L_NO_MAC" 'printf "# runs-on: ubuntu-24.04\n" >> "$IA/.swiftlint.yml"'
    control macos-word "$L_NO_MAC" 'printf "CI uses macos-15.\n" >> "$IA/CLAUDE.md"'
    # 10. dependabot
    control dependabot-no-swift "$L_DEP_ECO" 'sub "'"$DEP"'" "s/package-ecosystem: swift/package-ecosystem: pip/"'
    control dependabot-extra-eco "$L_DEP_ECO" \
        'printf "  - package-ecosystem: npm\n    directory: /\n    schedule:\n      interval: weekly\n" >> "'"$DEP"'"'
    control dependabot-swift-dir "$L_DEP_SWIFT" 'sub "'"$DEP"'" "/package-ecosystem: swift/,\$ s#directory: /#directory: /app#"'
    control dependabot-swift-daily "$L_DEP_SWIFT" 'sub "'"$DEP"'" "/package-ecosystem: swift/,\$ s/interval: weekly/interval: daily/"'
    control dependabot-swift-schedule-string "$L_DEP_SWIFT" \
        'sub "'"$DEP"'" "/package-ecosystem: swift/,\$ {/interval: weekly/d;}"; sub "'"$DEP"'" "/package-ecosystem: swift/,\$ s/^    schedule:\$/    schedule: weekly/"'
    # 11. CLAUDE.md
    control claude-no-brew "$L_CLAUDE_BREW" 'sub "$IA/CLAUDE.md" "s/brew install swiftlint/brew install lint/"'
    control claude-no-deployment "$L_CLAUDE_DEPLOY" 'sub "$IA/CLAUDE.md" "s/^## Deployment\$/## Release/"'
    control claude-no-sideload "$L_CLAUDE_DEPLOY" 'sub "$IA/CLAUDE.md" "s/sideload/install/g"'
    control claude-no-xcode-in-deployment "$L_CLAUDE_DEPLOY" 'sub "$IA/CLAUDE.md" "/^## Deployment\$/,/^## Key/ s/Xcode/the IDE/g"'
    control claude-block-edited "$L_CLAUDE_BLOCK" 'sub "$IA/CLAUDE.md" "s/One PR for each/One PR per/"'
    control claude-block-source "$L_CLAUDE_BLOCK" 'sub "$T/claude-block.md" "s/One PR for each/One PR per/"'
    control claude-table-test "$L_CLAUDE_TABLE" 'sub "$IA/CLAUDE.md" "s/^\| \`\{\{test\}\}\` \|/| \`make test\` |/"'
    control claude-table-lint "$L_CLAUDE_TABLE" 'sub "$IA/CLAUDE.md" "s/^\| \`swiftlint lint --strict\` \|/| \`swiftlint\` |/"'
    # 12. placeholders and project names
    control placeholder-extra "$L_PLACE_SET" 'printf "Run {{lint}}.\n" >> "$IA/CLAUDE.md"'
    control placeholder-unlisted-doc "$L_PLACE_DOC" 'sub "$D" "s/\{\{app_description\}\}/{{app_summary}}/g"'
    control project-fact-name "$L_DENY" 'printf "ElanRegistry\n" >> "$IA/CLAUDE.md"'
    control project-fact-dryfire "$L_DENY" 'printf "DryFireTimer\n" >> "$IA/.claude/rules/ios-review.md"'
    # 13. settings.json
    control settings-allow-missing "$L_SETTINGS" 'sub "$IA/.claude/settings.json" "/swiftlint lint:/d"'
    control settings-allow-extra "$L_SETTINGS" 'sub "$IA/.claude/settings.json" "s#\"Bash\(xcodebuild test:\*\)\"#\"Bash(xcodebuild test:*)\", \"Bash(xcodebuild build:*)\"#"'
    control settings-deny-missing "$L_SETTINGS" 'sub "$IA/.claude/settings.json" "/Read\(\.\/\.build/d"'
    control settings-template-grew "$L_SETTINGS" 'sub "$S" "s/\"Bash\(flow-repo:\*\)\",/\"Bash(flow-repo:*)\", \"Bash(flow-new:*)\",/"'
    # 14. .gitignore
    control gitignore-derived "$L_IGN_YES" 'sub "'"$GI"'" "/^DerivedData\//d"'
    control gitignore-build "$L_IGN_YES" 'sub "'"$GI"'" "/^build\//d"'
    control gitignore-xcuserdata "$L_IGN_YES" 'sub "'"$GI"'" "/^xcuserdata\//d"'
    control gitignore-xcuserstate "$L_IGN_YES" 'sub "'"$GI"'" "/^\*\.xcuserstate\$/d"'
    control gitignore-spm-build "$L_IGN_YES" 'sub "'"$GI"'" "/^\.build\//d"'
    control gitignore-p12 "$L_IGN_YES" 'sub "'"$GI"'" "/^\*\.p12\$/d"'
    control gitignore-cer "$L_IGN_YES" 'sub "'"$GI"'" "/^\*\.cer\$/d"'
    control gitignore-provisionprofile "$L_IGN_YES" 'sub "'"$GI"'" "/^\*\.provisionprofile\$/d"'
    control gitignore-swiftpm "$L_IGN_YES" 'sub "'"$GI"'" "/^\.swiftpm\//d"'
    control gitignore-profile "$L_IGN_YES" 'sub "'"$GI"'" "/^\*\.mobileprovision\$/d"'
    control gitignore-env "$L_IGN_YES" 'sub "'"$GI"'" "/^\.env\$/d"'
    control gitignore-env-name "$L_IGN_YES" 'sub "'"$GI"'" "/^\.env\.\*\$/d"'
    control gitignore-plans "$L_IGN_YES" 'sub "'"$GI"'" "/^docs\/plans/d"'
    control gitignore-ds-store "$L_IGN_YES" 'sub "'"$GI"'" "/^\.DS_Store\$/d"'
    control gitignore-example "$L_IGN_NO" 'sub "'"$GI"'" "/^!\.env\.example\$/d"'
    control gitignore-package-resolved "$L_IGN_NO" 'printf "Package.resolved\n" >> "'"$GI"'"'
    control gitignore-pbxproj "$L_IGN_NO" 'printf "*.pbxproj\n" >> "'"$GI"'"'
    control gitignore-xcscheme "$L_IGN_NO" 'printf "*.xcscheme\n" >> "'"$GI"'"'
    control gitignore-swift-sources "$L_IGN_NO" 'printf "*.swift\n" >> "'"$GI"'"'
    # 15. whitespace
    control whitespace-trailing "$L_WS" 'printf "trailing \n" >> "$IA/.claude/rules/ios-review.md"'
    control whitespace-dotfile "$L_WS" 'printf "\n" >> "'"$GI"'"'
    control whitespace-no-final-newline "$L_WS" 'printf "x" >> "$IA/.swiftlint.yml"'
    # 16. manual steps
    control doc-no-brew "$L_MANUAL" 'sub "$D" "/^For \`ios-app\`:\$/,\$ s/brew install swiftlint/brew install lint/"'
    control doc-no-precommit "$L_MANUAL" 'sub "$D" "/^For \`ios-app\`:\$/,\$ s/pre-commit install/pre-commit run/"'
    control doc-no-swift-entry "$L_MANUAL" 'sub "$D" "/^For \`ios-app\`:\$/,\$ s/\`swift\`/\`spm\`/g"'
    control doc-no-section "$L_MANUAL" 'sub "$D" "s/^For \`ios-app\`:\$/For the iOS app:/"'
    controls_report
fi

harness_report
