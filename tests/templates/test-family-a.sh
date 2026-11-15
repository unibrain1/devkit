#!/bin/bash
#
# Tests for the family A templates: plugins/flow/templates/static-site-cloudflare/
# and static-site-host/. Each folder holds the files of a new Node static
# site, at the paths that the target repo uses.
#
# Checks for each family: the exact file set, the baseline paths that the
# folder overrides, the override content, YAML and JSON validity, the ci.yml
# caller (ref, inputs, action pins), the Dependabot entries, the host
# pre-commit hook, flow-project-check on project.md, settings.json against
# templates/settings.json, the flow block in CLAUDE.md, package.json,
# .gitignore, placeholders, project facts, and whitespace.
#
# Override check: it is semantic. Every entry of the baseline file (each
# Dependabot update, each pre-commit repo with its hooks) must be present,
# equal, in the parsed override, and the other top-level keys must be equal.
# A second check requires every line of the baseline file, comments too, in
# the override. A baseline change that the override does not copy fails.
#
# Each check has a break-it control. The control copies the templates to a
# scratch folder, breaks one thing, runs this script on the copy, and
# expects the named check to fail. Set FAMILY_A_NO_CONTROLS=1 to skip them.
#
# Env overrides, for the controls on scratch copies:
#   TEMPLATES_DIR      the templates folder: baseline/, static-site-*/, claude-block.md
#   BASELINE_DIR       the baseline folder (default: $TEMPLATES_DIR/baseline)
#   FAMILIES_DOC       docs/families.md
#   NODE_SITE          .github/workflows/node-site.yml
#   SETTINGS_TEMPLATE  templates/settings.json
#   FLOW_BIN           the folder with flow-project-check
#
# Usage: bash tests/templates/test-family-a.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# SC2016: the control mutations are single-quoted on purpose. eval expands
# them inside the control. SC2034: eval reads CF and HO. SC2155: a local that
# holds a command result needs no exit status.
# shellcheck disable=SC2016,SC2034,SC2155

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATES_DIR="${TEMPLATES_DIR:-$REAL_REPO/plugins/flow/templates}"
BASELINE_DIR="${BASELINE_DIR:-$TEMPLATES_DIR/baseline}"
FAMILIES_DOC="${FAMILIES_DOC:-$REAL_REPO/docs/families.md}"
NODE_SITE="${NODE_SITE:-$REAL_REPO/.github/workflows/node-site.yml}"
SETTINGS_TEMPLATE="${SETTINGS_TEMPLATE:-$REAL_REPO/templates/settings.json}"
FLOW_BIN="${FLOW_BIN:-$REAL_REPO/plugins/flow/bin}"
PIN_CHECK="$REAL_REPO/.github/scripts/check-action-pins.sh"
CLAUDE_BLOCK="$TEMPLATES_DIR/claude-block.md"

TMPROOT="$(mktemp -d)" || exit 1

# Names that must not appear in a template: they are project facts.
DENY_LIST="TeamCroc BurgessMachineWorks BurgessGunWorks CCS-Website ElanRegistry devkit-sandbox"

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
    && command -v jq >/dev/null 2>&1; then
    pass "ruby with yaml and json, and jq, are available"
else
    fail "ruby with yaml and json, and jq, are available" "install ruby and jq"
    harness_report
fi

# y2j <file>: JSON on stdout, nonzero on a parse error. The file must be in
# the cache that the next two lines fill.
YJ="$TMPROOT/yj"; mkdir -p "$YJ"
# shellcheck disable=SC2046 # the file names hold no space
ruby "$TMPROOT/y2j.rb" "$YJ" $(find "$TEMPLATES_DIR" "$BASELINE_DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) | sort -u) "$NODE_SITE" 2>/dev/null
y2j() { local c="$YJ/$(printf '%s' "$1" | tr / _)"; [ -f "$c" ] && cat "$c"; }

# jsonc_ok <file>: true when the file is one JSON object after the // comment
# lines go. An empty or comment-only file is not.
jsonc_ok() { grep -v '^[[:space:]]*//' "$1" | jq -e 'type == "object"' >/dev/null 2>&1; }

# files_in <dir>: each file below <dir>, as a relative path, sorted.
files_in() {
    (cd "$1" 2>/dev/null && find . -type f ! -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort)
}

# strip_gha <file>: the file with each ${{ ... }} GitHub expression removed.
strip_gha() { sed -E 's/\$\{\{[^}]*\}\}//g' "$1"; }

# jq filter: true when every key and every array entry of $t is in $f.
SUPERSET='def sup($t; $f):
    if ($t | type) == "object" then
        ($f | type) == "object"
        and all($t | keys[]; . as $k | sup($t[$k]; $f[$k]))
    elif ($t | type) == "array" then
        ($f | type) == "array"
        and all($t[]; . as $e | any($f[]; . == $e))
    else $t == $f end;
sup($t; $f)'

# --- the checks --------------------------------------------------------
# check_lint_php <package.json>: runs the lint:php script with a stub php
# that fails on a file named bad.php. A bad file must fail the script. A
# bad file in node_modules/, vendor/, or _site/ must not.
check_lint_php() {
    local script work bin rc got=""
    script="$(jq -r '.scripts["lint:php"] // ""' "$1")"
    work="$TMPROOT/lint-php"
    bin="$work/bin"
    rm -rf "$work"; mkdir -p "$bin"
    printf '#!/bin/sh\ncase "$2" in *bad.php) exit 255 ;; esac\nexit 0\n' > "$bin/php"
    chmod +x "$bin/php"
    # lint_php_case <name> <want: fail or pass> <file> ...
    lint_php_case() {
        local name="$1" want="$2" f
        shift 2
        mkdir -p "$work/$name"
        for f in "$@"; do mkdir -p "$work/$name/$(dirname "$f")"; : > "$work/$name/$f"; done
        (cd "$work/$name" && PATH="$bin:$PATH" sh -c "$script" >/dev/null 2>&1); rc=$?
        if [ "$want" = fail ] && [ "$rc" -eq 0 ]; then got="$got [$name: exit 0]"; fi
        if [ "$want" = pass ] && [ "$rc" -ne 0 ]; then got="$got [$name: exit $rc]"; fi
    }
    lint_php_case bad fail a/good.php a/bad.php
    lint_php_case good pass a/good.php b/c/good.php
    lint_php_case none pass README.md
    lint_php_case skipped pass good.php node_modules/x/bad.php vendor/bad.php _site/bad.php
    if [ -z "$got" ]; then
        pass "host: lint:php fails on a bad file and skips node_modules, vendor, and _site"
    else
        fail "host: lint:php fails on a bad file and skips node_modules, vendor, and _site" "$got"
    fi
}

# check_family <kind> <dir>: kind is cloudflare or host.
check_family() {
    local kind="$1" dir="$2" want allowed got f rel base_rel files base_files
    local ci cij dep depj pc pcj

    files="$(files_in "$dir")"
    base_files="$(files_in "$BASELINE_DIR")"

    # 1. exact file set
    want=".claude/project.md
.claude/rules/site-review.md
.claude/settings.json
.github/dependabot.yml
.github/workflows/ci.yml
.gitignore
.markdownlint-cli2.jsonc
.nvmrc
CLAUDE.md
eleventy.config.js
package.json"
    allowed=".github/dependabot.yml"
    if [ "$kind" = host ]; then
        want="$(printf '%s\n.pre-commit-config.yaml\n.stylelintrc.json\n' "$want" | LC_ALL=C sort)"
        allowed=".github/dependabot.yml
.pre-commit-config.yaml"
    fi
    got="$files"
    if [ "$got" = "$want" ]; then
        pass "$kind: file set is exact"
    else
        fail "$kind: file set is exact" "got: $(printf '%s' "$got" | tr '\n' ' ')"
    fi

    # 2. only the allowed baseline paths appear in the folder
    got=""
    while IFS= read -r base_rel; do
        [ -n "$base_rel" ] || continue
        if [ -e "$dir/$base_rel" ] && ! printf '%s\n' "$allowed" | grep -qFx -- "$base_rel"; then
            got="$got $base_rel"
        fi
    done <<EOF
$base_files
EOF
    if [ -z "$got" ] && [ -n "$base_files" ]; then
        pass "$kind: only the allowed baseline paths are overridden"
    else
        fail "$kind: only the allowed baseline paths are overridden" "not allowed:${got:- (baseline folder empty)}"
    fi

    # 3. YAML and JSON parse
    cij="{}"; depj="{}"; pcj="{}"
    ci="$dir/.github/workflows/ci.yml"
    dep="$dir/.github/dependabot.yml"
    pc="$dir/.pre-commit-config.yaml"
    for rel in .github/workflows/ci.yml .github/dependabot.yml .pre-commit-config.yaml; do
        [ -e "$dir/$rel" ] || continue
        if f="$(y2j "$dir/$rel")"; then
            pass "$kind: parses: $rel"
            case "$rel" in
                .github/workflows/ci.yml) cij="$f" ;;
                .github/dependabot.yml) depj="$f" ;;
                .pre-commit-config.yaml) pcj="$f" ;;
            esac
        else
            fail "$kind: parses: $rel"
        fi
    done
    for rel in .claude/settings.json package.json .stylelintrc.json; do
        [ -e "$dir/$rel" ] || continue
        if jq empty "$dir/$rel" >/dev/null 2>&1; then
            pass "$kind: parses: $rel"
        else
            fail "$kind: parses: $rel"
        fi
    done
    if jsonc_ok "$dir/.markdownlint-cli2.jsonc"; then
        pass "$kind: parses: .markdownlint-cli2.jsonc"
    else
        fail "$kind: parses: .markdownlint-cli2.jsonc"
    fi

    # 4. each override holds the baseline content
    if [ -e "$dir/.github/dependabot.yml" ]; then
        got="$(y2j "$BASELINE_DIR/.github/dependabot.yml")"
        if [ -z "$got" ]; then
            got="baseline dependabot.yml is missing or does not parse"
        else
            got="$(printf '%s' "$got" | jq -r --argjson f "$depj" '
            . as $b
            | [ (if $b.version == $f.version then empty else "version" end),
                (if ($b | del(.updates)) == ($f | del(.updates)) then empty else "top-level keys" end),
                ($b.updates[] | . as $e
                    | select(any(($f.updates // [])[]; . == $e) | not)
                    | "update " + .["package-ecosystem"]) ] | join(", ")' 2>&1)"
            got="$got$(grep -vxFf "$dep" "$BASELINE_DIR/.github/dependabot.yml" 2>/dev/null | sed 's/^/ line missing: /' | tr '\n' ' ')"
        fi
        if [ -z "$got" ]; then
            pass "$kind: dependabot override holds the baseline content"
        else
            fail "$kind: dependabot override holds the baseline content" "$got"
        fi
    fi
    if [ "$kind" = host ]; then
        got="$(y2j "$BASELINE_DIR/.pre-commit-config.yaml")"
        if [ -z "$got" ]; then
            got="baseline .pre-commit-config.yaml is missing or does not parse"
        else
            got="$(printf '%s' "$got" | jq -r --argjson f "$pcj" '
            . as $b
            | [ (if ($b | del(.repos)) == ($f | del(.repos)) then empty else "top-level keys" end),
                ($b.repos[] | . as $e
                    | select(any(($f.repos // [])[]; . == $e) | not)
                    | "repo " + .repo) ] | join(", ")' 2>&1)"
            got="$got$(grep -vxFf "$pc" "$BASELINE_DIR/.pre-commit-config.yaml" 2>/dev/null | sed 's/^/ line missing: /' | tr '\n' ' ')"
        fi
        if [ -z "$got" ]; then
            pass "$kind: pre-commit override holds the baseline content"
        else
            fail "$kind: pre-commit override holds the baseline content" "$got"
        fi
    fi

    # 5. ci.yml caller
    got="$(printf '%s' "$cij" | jq -r '[.jobs[]?.uses] | join(",")')"
    if [ "$got" = "unibrain1/devkit/.github/workflows/node-site.yml@main" ]; then
        pass "$kind: ci.yml uses node-site.yml@main"
    else
        fail "$kind: ci.yml uses node-site.yml@main" "uses: $got"
    fi
    got="$(jq -nr --argjson c "$cij" --argjson r "$(y2j "$NODE_SITE" || echo '{}')" '
        [$c.jobs[]? | (.with // {}) | keys[]] - (($r.on.workflow_call.inputs // {}) | keys) | join(",")')"
    if [ -z "$got" ] && [ -f "$NODE_SITE" ]; then
        pass "$kind: each with: key of ci.yml is an input of node-site.yml"
    else
        fail "$kind: each with: key of ci.yml is an input of node-site.yml" "not declared: ${got:-(node-site.yml missing)}"
    fi
    if [ "$kind" = host ]; then
        got="$(printf '%s' "$cij" | jq -r '[.jobs[]?.with.lint_script] | join(",")')"
        if [ "$got" = "lint" ]; then
            pass "host: ci.yml sets lint_script: lint"
        else
            fail "host: ci.yml sets lint_script: lint" "lint_script: $got"
        fi
    else
        if [ "$(printf '%s' "$cij" | jq '[.jobs[]? | has("with")] | any')" = "false" ]; then
            pass "cloudflare: ci.yml has no with:"
        else
            fail "cloudflare: ci.yml has no with:"
        fi
        if grep -Eq '^[[:space:]]*#[[:space:]]*pages_functions: true' "$ci" 2>/dev/null; then
            pass "cloudflare: ci.yml comment shows pages_functions: true"
        else
            fail "cloudflare: ci.yml comment shows pages_functions: true"
        fi
    fi
    if [ -x "$PIN_CHECK" ] && [ -d "$dir/.github/workflows" ]; then
        got="$("$PIN_CHECK" "$dir/.github/workflows" 2>&1)"; rel=$?
        if [ "$rel" -eq 0 ] && grep -Eq '^[[:space:]-]*uses:' "$ci"; then
            pass "$kind: check-action-pins.sh passes on the workflows"
        else
            fail "$kind: check-action-pins.sh passes on the workflows" "exit: $rel" "$got"
        fi
    else
        fail "$kind: check-action-pins.sh passes on the workflows" "script or folder missing"
    fi

    # 6. Dependabot entries and prefix
    want="github-actions npm"
    [ "$kind" = host ] && want="composer github-actions npm"
    got="$(printf '%s' "$depj" | jq -r '[.updates[]?["package-ecosystem"]] | sort | join(" ")')"
    if [ "$got" = "$want" ]; then
        pass "$kind: dependabot ecosystems are: $want"
    else
        fail "$kind: dependabot ecosystems are: $want" "got: $got"
    fi
    base_rel="$(y2j "$BASELINE_DIR/.github/dependabot.yml" | jq -r '.updates[0]["commit-message"].prefix')"
    got="$(printf '%s' "$depj" | jq -r --arg p "$base_rel" '
        [.updates[]? | select(.["package-ecosystem"] != "github-actions")
         | select(.["commit-message"].prefix != $p) | .["package-ecosystem"]] | join(",")')"
    if [ -z "$got" ] && [ -n "$base_rel" ] && [ "$base_rel" != null ]; then
        pass "$kind: new dependabot entries use the baseline prefix"
    else
        fail "$kind: new dependabot entries use the baseline prefix" "baseline prefix: $base_rel" "other prefix in: $got"
    fi
    if [ "$kind" = host ]; then
        got="$(printf '%s' "$depj" | jq -r '[.updates[]? | select(.["package-ecosystem"] == "composer") | .directory] | join(",")')"
        if [ "$got" = "/" ]; then
            pass "host: dependabot composer directory is /"
        else
            fail "host: dependabot composer directory is /" "directory: $got"
        fi

        # 7. host pre-commit hook
        got="$(printf '%s' "$pcj" | jq -r '
            [.repos[]? | select(.repo == "local") | .hooks[]
             | select((.entry // "" | contains("npm run lint"))
                 and (.pass_filenames == false)
                 and ((.files // "x") as $re
                      | ("a.css" | test($re)) and ("a.php" | test($re))
                      and (("a.md" | test($re)) | not)))] | length')"
        if [ "$got" = "1" ]; then
            pass "host: pre-commit has one local hook that runs npm run lint on css and php"
        else
            fail "host: pre-commit has one local hook that runs npm run lint on css and php" "matching hooks: $got"
        fi
    fi

    # 8. flow-project-check on project.md in a temp git repo
    if [ -e "$dir/.claude/project.md" ]; then
        rel="$TMPROOT/pc-$kind"
        rm -rf "$rel"; mkdir -p "$rel/.claude"
        cp "$dir/.claude/project.md" "$rel/.claude/project.md"
        git -C "$rel" init -q 2>/dev/null
        got="$(cd "$rel" && "$FLOW_BIN/flow-project-check" 2>&1)"; f=$?
        if [ "$f" -eq 0 ]; then
            pass "$kind: flow-project-check passes on project.md"
        else
            fail "$kind: flow-project-check passes on project.md" "exit: $f" "$got"
        fi
    else
        fail "$kind: flow-project-check passes on project.md" "project.md missing"
    fi

    # 9. settings.json
    got="$(jq -n --argjson t "$(jq -c . "$SETTINGS_TEMPLATE" 2>/dev/null || echo null)" \
        --argjson f "$(jq -c . "$dir/.claude/settings.json" 2>/dev/null || echo null)" "$SUPERSET")"
    if [ "$got" = "true" ]; then
        pass "$kind: settings.json is a superset of templates/settings.json"
    else
        fail "$kind: settings.json is a superset of templates/settings.json"
    fi
    got="$(jq -r '
        ["Bash(npm run build:*)", "Bash(npm run lint:*)"] as $a
        | ["Read(./node_modules/**)", "Edit(./node_modules/**)", "Read(./_site/**)", "Edit(./_site/**)"] as $d
        | (($a - (.permissions.allow // [])) + ($d - (.permissions.deny // []))) | join(", ")' \
        "$dir/.claude/settings.json" 2>&1)"
    if [ -z "$got" ]; then
        pass "$kind: settings.json adds the npm allow rules and the node_modules and _site deny rules"
    else
        fail "$kind: settings.json adds the npm allow rules and the node_modules and _site deny rules" "missing: $got"
    fi

    # 10. CLAUDE.md
    got="$(awk '/^<!-- flow:begin/{p=1} p{print} /^<!-- flow:end -->$/{p=0}' "$dir/CLAUDE.md" 2>/dev/null)"
    if [ -n "$got" ] && [ "$got" = "$(cat "$CLAUDE_BLOCK" 2>/dev/null)" ] \
        && [ "$(grep -c '^<!-- flow:begin' "$dir/CLAUDE.md")" = "1" ]; then
        pass "$kind: CLAUDE.md flow block equals claude-block.md"
    else
        fail "$kind: CLAUDE.md flow block equals claude-block.md"
    fi
    if [ "$kind" = host ]; then
        got=""
        for rel in 'push to `main`' webhook 'npm run build' rsync; do
            grep -qiF -- "$rel" "$dir/CLAUDE.md" 2>/dev/null || got="$got [$rel]"
        done
        if [ -z "$got" ]; then
            pass "host: CLAUDE.md describes the push-to-host deploy"
        else
            fail "host: CLAUDE.md describes the push-to-host deploy" "missing:$got"
        fi
    else
        if grep -qF 'pages_functions' "$dir/CLAUDE.md" 2>/dev/null; then
            pass "cloudflare: CLAUDE.md mentions pages_functions"
        else
            fail "cloudflare: CLAUDE.md mentions pages_functions"
        fi
    fi

    # 11. package.json
    got="$(jq -r '[(.scripts.build // "" | select(. != "")), (.scripts.lint // "" | select(. != ""))] | length' \
        "$dir/package.json" 2>/dev/null)"
    if [ "$got" = "2" ]; then
        pass "$kind: package.json has scripts build and lint"
    else
        fail "$kind: package.json has scripts build and lint"
    fi
    if [ "$kind" = host ]; then
        got="$(jq -r '
            (.scripts // {}) as $s
            | [ (if ($s.lint // "" | contains("lint:css")) then empty else "lint does not run lint:css" end),
                (if ($s.lint // "" | contains("lint:php")) then empty else "lint does not run lint:php" end),
                (if ($s["lint:css"] // "" | contains("stylelint")) then empty else "lint:css has no stylelint" end),
                (if ($s["lint:php"] // "" | contains("php -l")) then empty else "lint:php has no php -l" end),
                (if ($s["lint:php"] // "" | contains("php -l {} +")) then "lint:php passes a list of files to one php -l call" else empty end)
              ] | join(", ")' "$dir/package.json" 2>&1)"
        if [ -z "$got" ]; then
            pass "host: package.json lint runs lint:css (stylelint) and lint:php (php -l for each file)"
        else
            fail "host: package.json lint runs lint:css (stylelint) and lint:php (php -l for each file)" "$got"
        fi
        check_lint_php "$dir/package.json"
    fi
    if [ -e "$dir/package-lock.json" ]; then
        fail "$kind: no package-lock.json in the folder"
    else
        pass "$kind: no package-lock.json in the folder"
    fi

    # 12. .gitignore
    got=""
    for rel in 'docs/plans/' '.env' '.env.*' '.dev.vars'; do
        grep -qFx -- "$rel" "$dir/.gitignore" 2>/dev/null || got="$got [$rel]"
    done
    if [ -z "$got" ]; then
        pass "$kind: .gitignore has docs/plans/, .env, .env.*, and .dev.vars"
    else
        fail "$kind: .gitignore has docs/plans/, .env, .env.*, and .dev.vars" "missing:$got"
    fi

    # 13. placeholders
    got=""
    while IFS= read -r f; do
        [ -f "$dir/$f" ] || continue
        for rel in $(strip_gha "$dir/$f" | grep -oE '\{\{[a-z_]+\}\}' | sort -u); do
            grep -qF -- "\`$rel\`" "$FAMILIES_DOC" 2>/dev/null || got="$got $rel($f)"
        done
    done <<EOF
$files
EOF
    if [ -z "$got" ] && [ -f "$FAMILIES_DOC" ]; then
        pass "$kind: each placeholder is listed in docs/families.md"
    else
        fail "$kind: each placeholder is listed in docs/families.md" "not listed:${got:- (families.md missing)}"
    fi
    got=""
    while IFS= read -r f; do
        case "$f" in
            *.yml|*.yaml|*.js) ;;
            *) continue ;;
        esac
        strip_gha "$dir/$f" | grep -qF '{{' && got="$got $f"
    done <<EOF
$files
EOF
    if [ -z "$got" ]; then
        pass "$kind: no placeholder in a YAML or JS file"
    else
        fail "$kind: no placeholder in a YAML or JS file" "found in:$got"
    fi

    # 14. no project fact
    got=""
    for rel in $DENY_LIST; do
        f="$(grep -rliF -e "$rel" "$dir" 2>/dev/null | tr '\n' ' ')"
        [ -z "$f" ] || got="$got [$rel: $f]"
    done
    if [ -z "$got" ]; then
        pass "$kind: no project name or host in a template file"
    else
        fail "$kind: no project name or host in a template file" "found:$got"
    fi

    # 15. whitespace
    got=""
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
    if [ -z "$got" ]; then
        pass "$kind: clean whitespace"
    else
        fail "$kind: clean whitespace" "problems:$got"
    fi
}

# FAMILY_A_ONLY=cloudflare or host runs the checks of one family. A control
# sets it, so that it runs half of the checks.
if [ "${FAMILY_A_ONLY:-}" != "host" ]; then
    check_family cloudflare "$TEMPLATES_DIR/static-site-cloudflare"
fi
if [ "${FAMILY_A_ONLY:-}" != "cloudflare" ]; then
    check_family host "$TEMPLATES_DIR/static-site-host"
fi

# --- break-it controls -------------------------------------------------
# control <name> <expected-failing-check> <mutation>
# <mutation> runs with T, D, N, S set (templates, families doc, node-site,
# settings template, all in a scratch copy). The check script runs on the
# copy and must print "FAIL: <expected-failing-check>" and exit 1.
sub() { # sub <file> <sed -E expression>
    sed -E -e "$2" "$1" > "$1.new" && mv "$1.new" "$1"
}
# setscript <package.json> <script name> <value>: set one npm script.
setscript() {
    jq --arg k "$2" --arg v "$3" '.scripts[$k] = $v' "$1" > "$1.new" && mv "$1.new" "$1"
}
# fresh_copy <scratch-dir>: copy the inputs, and set T, D, N, S, CF, HO.
fresh_copy() {
    SCR="$1"
    rm -rf "$SCR"; mkdir -p "$SCR"
    cp -R "$TEMPLATES_DIR" "$SCR/templates"
    cp "$FAMILIES_DOC" "$SCR/families.md"
    cp "$NODE_SITE" "$SCR/node-site.yml"
    cp "$SETTINGS_TEMPLATE" "$SCR/settings.json"
    T="$SCR/templates"; D="$SCR/families.md"; N="$SCR/node-site.yml"; S="$SCR/settings.json"
    CF="$T/static-site-cloudflare"; HO="$T/static-site-host"
}
# run_on_copy [family]: run this script on the copy. Output on stdout.
run_on_copy() {
    FAMILY_A_NO_CONTROLS=1 FAMILY_A_ONLY="${1:-}" TEMPLATES_DIR="$T" BASELINE_DIR="$T/baseline" \
        FAMILIES_DOC="$D" NODE_SITE="$N" SETTINGS_TEMPLATE="$S" FLOW_BIN="$FLOW_BIN" bash "$SELF" 2>&1
}
# The controls run in parallel. Each one writes its result to $RES/<n>.
RES="$TMPROOT/res"; mkdir -p "$RES"
NCTL=0
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
[ "$JOBS" -gt 8 ] && JOBS=8
[ "$JOBS" -lt 2 ] && JOBS=2
# control <name> <expected-failing-check> <mutation>
control() {
    local name="$1" expect="$2" mutation="$3" n fam=""
    NCTL=$((NCTL + 1)); n=$NCTL
    printf '%s\n%s\n' "$name" "$expect" > "$RES/$n.name"
    case "$expect" in
        cloudflare:*) fam=cloudflare ;;
        host:*) fam=host ;;
    esac
    (
        local out rc
        fresh_copy "$TMPROOT/scratch-$n"
        eval "$mutation"
        out="$(run_on_copy "$fam")"; rc=$?
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

if [ "${FAMILY_A_NO_CONTROLS:-}" != "1" ]; then
    # The unbroken copy must pass, or every control proves nothing.
    fresh_copy "$TMPROOT/scratch-clean"
    out="$(run_on_copy)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "control clean-copy: the unbroken scratch copy passes"
    else
        fail "control clean-copy: the unbroken scratch copy passes" "exit: $rc" "$(printf '%s\n' "$out" | grep '^FAIL' | head -5)"
    fi

    control file-extra "cloudflare: file set is exact" 'touch "$CF/extra.txt"'
    control file-missing "host: file set is exact" 'rm "$HO/.nvmrc"'
    control override-cloudflare-workflow "cloudflare: only the allowed baseline paths are overridden" \
        'cp "$T/baseline/.github/workflows/claude.yml" "$CF/.github/workflows/claude.yml"'
    control override-cloudflare-precommit "cloudflare: only the allowed baseline paths are overridden" \
        'cp "$T/baseline/.pre-commit-config.yaml" "$CF/.pre-commit-config.yaml"'
    control override-host-secrets "host: only the allowed baseline paths are overridden" \
        'cp "$T/baseline/.github/workflows/secrets-scan.yml" "$HO/.github/workflows/secrets-scan.yml"'
    control baseline-dependabot-changed "cloudflare: dependabot override holds the baseline content" \
        'sub "$T/baseline/.github/dependabot.yml" "s/interval: weekly/interval: daily/"'
    control baseline-dependabot-comment "host: dependabot override holds the baseline content" \
        'sub "$T/baseline/.github/dependabot.yml" "s/^# Baseline Dependabot/# Base Dependabot/"'
    control baseline-dependabot-missing "cloudflare: dependabot override holds the baseline content" \
        'rm "$T/baseline/.github/dependabot.yml"'
    control baseline-precommit-missing "host: pre-commit override holds the baseline content" \
        'rm "$T/baseline/.pre-commit-config.yaml"'
    control baseline-precommit-rev "host: pre-commit override holds the baseline content" \
        'sub "$T/baseline/.pre-commit-config.yaml" "s/rev: v8\.30\.1/rev: v8.30.2/"'
    control baseline-precommit-comment "host: pre-commit override holds the baseline content" \
        'sub "$T/baseline/.pre-commit-config.yaml" "s/gitleaks scans only/gitleaks reads only/"'
    control override-dependabot-drops-entry "host: dependabot override holds the baseline content" \
        'sub "$HO/.github/dependabot.yml" "s/package-ecosystem: github-actions/package-ecosystem: pip/"'
    control yaml-broken "cloudflare: parses: .github/workflows/ci.yml" \
        'printf "a: [1, 2\nb: : :\n" > "$CF/.github/workflows/ci.yml"'
    control json-broken "host: parses: .claude/settings.json" \
        'printf "{ \"a\": \n" > "$HO/.claude/settings.json"'
    control jsonc-empty "host: parses: .markdownlint-cli2.jsonc" \
        'printf "// only a comment\n" > "$HO/.markdownlint-cli2.jsonc"'
    control jsonc-broken "host: parses: .markdownlint-cli2.jsonc" \
        'printf "// c\n{ \"a\": \n" > "$HO/.markdownlint-cli2.jsonc"'
    control ci-ref "cloudflare: ci.yml uses node-site.yml@main" \
        'sub "$CF/.github/workflows/ci.yml" "s#node-site.yml@main#node-site.yml@v1#"'
    control ci-input-unknown "host: each with: key of ci.yml is an input of node-site.yml" \
        'printf "      bogus_input: x\n" >> "$HO/.github/workflows/ci.yml"'
    control ci-input-removed-from-reusable "host: each with: key of ci.yml is an input of node-site.yml" \
        'sub "$N" "s/^      lint_script:/      lint_script_x:/"'
    control ci-lint-script "host: ci.yml sets lint_script: lint" \
        'sub "$HO/.github/workflows/ci.yml" "s/lint_script: lint/lint_script: build/"'
    control ci-cloudflare-with "cloudflare: ci.yml has no with:" \
        'printf "    with:\n      pages_functions: true\n" >> "$CF/.github/workflows/ci.yml"'
    control ci-cloudflare-comment "cloudflare: ci.yml comment shows pages_functions: true" \
        'sub "$CF/.github/workflows/ci.yml" "s/pages_functions: true/pages_functions: yes/"'
    control ci-unpinned-action "cloudflare: check-action-pins.sh passes on the workflows" \
        'printf "  other:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/checkout@v4\n" >> "$CF/.github/workflows/ci.yml"'
    control dependabot-npm-removed "cloudflare: dependabot ecosystems are: github-actions npm" \
        'sub "$CF/.github/dependabot.yml" "s/package-ecosystem: npm/package-ecosystem: pip/"'
    control dependabot-prefix "host: new dependabot entries use the baseline prefix" \
        'sub "$HO/.github/dependabot.yml" "/package-ecosystem: npm/,\$ s/prefix: chore\(deps\)/prefix: chore(dep)/"'
    control dependabot-composer-dir "host: dependabot composer directory is /" \
        'sub "$HO/.github/dependabot.yml" "/package-ecosystem: composer/,\$ s#directory: /#directory: /app#"'
    control precommit-entry "host: pre-commit has one local hook that runs npm run lint on css and php" \
        'sub "$HO/.pre-commit-config.yaml" "s/entry: npm run lint/entry: npm test/"'
    control precommit-files "host: pre-commit has one local hook that runs npm run lint on css and php" \
        'sub "$HO/.pre-commit-config.yaml" "s/css\|php/css|md/"'
    control precommit-pass-filenames "host: pre-commit has one local hook that runs npm run lint on css and php" \
        'sub "$HO/.pre-commit-config.yaml" "s/pass_filenames: false/pass_filenames: true/"'
    control project-md-unknown-key "cloudflare: flow-project-check passes on project.md" \
        'printf -- "- bogus_key: \`x\`\n" >> "$CF/.claude/project.md"'
    control settings-allow-missing "host: settings.json is a superset of templates/settings.json" \
        'sub "$HO/.claude/settings.json" "/flow-repo:/d"'
    control settings-template-grew "cloudflare: settings.json is a superset of templates/settings.json" \
        'sub "$S" "s/\"Bash\(flow-repo:\*\)\",/\"Bash(flow-repo:*)\", \"Bash(flow-new:*)\",/"'
    control settings-npm-rule "cloudflare: settings.json adds the npm allow rules and the node_modules and _site deny rules" \
        'sub "$CF/.claude/settings.json" "s/npm run lint:/npm run lintx:/"'
    control settings-deny-rule "host: settings.json adds the npm allow rules and the node_modules and _site deny rules" \
        'sub "$HO/.claude/settings.json" "s#Edit\(\./_site/\*\*\)#Edit(./_siteX/**)#"'
    control claude-block-edited "host: CLAUDE.md flow block equals claude-block.md" \
        'sub "$HO/CLAUDE.md" "s/One PR for each/One PR per/"'
    control claude-block-source "cloudflare: CLAUDE.md flow block equals claude-block.md" \
        'sub "$T/claude-block.md" "s/hotfix branches/hotfix starts/"'
    control claude-host-deploy "host: CLAUDE.md describes the push-to-host deploy" \
        'sub "$HO/CLAUDE.md" "s/rsync/scp/"'
    control claude-cloudflare-functions "cloudflare: CLAUDE.md mentions pages_functions" \
        'sub "$CF/CLAUDE.md" "s/pages_functions/functions_flag/"'
    control package-no-lint "host: package.json has scripts build and lint" \
        'sub "$HO/package.json" "s/\"lint\":/\"lintx\":/"'
    control package-lint-no-php "host: package.json lint runs lint:css (stylelint) and lint:php (php -l for each file)" \
        'sub "$HO/package.json" "s/ \&\& npm run lint:php//"'
    control package-lint-php-list "host: package.json lint runs lint:css (stylelint) and lint:php (php -l for each file)" \
        'setscript "$HO/package.json" lint:php "find . -name \"*.php\" -exec php -l {} +"'
    control package-lint-php-status "host: lint:php fails on a bad file and skips node_modules, vendor, and _site" \
        'sub "$HO/package.json" "s/ \\|\\| s=1//"'
    control package-lint-php-vendor "host: lint:php fails on a bad file and skips node_modules, vendor, and _site" \
        'sub "$HO/package.json" "s#-not -path .\\./vendor/[*]. ##"'
    control package-lint-css "host: package.json lint runs lint:css (stylelint) and lint:php (php -l for each file)" \
        'setscript "$HO/package.json" lint:css "echo css"'
    control package-lock "cloudflare: no package-lock.json in the folder" \
        'printf "{}\n" > "$CF/package-lock.json"'
    control gitignore-plans "host: .gitignore has docs/plans/, .env, .env.*, and .dev.vars" \
        'sub "$HO/.gitignore" "/docs\/plans/d"'
    control gitignore-env "cloudflare: .gitignore has docs/plans/, .env, .env.*, and .dev.vars" \
        'sub "$CF/.gitignore" "/^\.env$/d"'
    control gitignore-env-star "host: .gitignore has docs/plans/, .env, .env.*, and .dev.vars" \
        'sub "$HO/.gitignore" "/^\.env\.\*$/d"'
    control gitignore-dev-vars "cloudflare: .gitignore has docs/plans/, .env, .env.*, and .dev.vars" \
        'sub "$CF/.gitignore" "/^\.dev\.vars$/d"'
    control placeholder-unlisted-doc "host: each placeholder is listed in docs/families.md" \
        'sub "$D" "s/\{\{package_name\}\}/{{pkg}}/"'
    control placeholder-unlisted-new "cloudflare: each placeholder is listed in docs/families.md" \
        'printf "{{extra_key}}\n" >> "$CF/CLAUDE.md"'
    control placeholder-in-yaml "cloudflare: no placeholder in a YAML or JS file" \
        'printf "# {{site_name}}\n" >> "$CF/.github/dependabot.yml"'
    control project-fact-name "host: no project name or host in a template file" \
        'printf "TeamCroc\n" >> "$HO/CLAUDE.md"'
    control project-fact-lowercase "cloudflare: no project name or host in a template file" \
        'printf "// see the teamcroc server\n" >> "$CF/eleventy.config.js"'
    control project-fact-second-name "host: no project name or host in a template file" \
        'printf "// CCS-Website\n" >> "$HO/eleventy.config.js"'
    control whitespace-trailing "cloudflare: clean whitespace" \
        'printf "24 \n" > "$CF/.nvmrc"'
    control whitespace-tab "host: clean whitespace" \
        'printf "\t# tab\n" >> "$HO/.github/workflows/ci.yml"'
    control whitespace-blank-end "host: clean whitespace" \
        'printf "\n" >> "$HO/eleventy.config.js"'
    control whitespace-no-newline "cloudflare: clean whitespace" \
        'printf "24" > "$CF/.nvmrc"'
    controls_report
fi

harness_report
