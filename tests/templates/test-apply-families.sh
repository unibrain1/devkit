#!/bin/bash
#
# End-to-end test of flow-template --apply on the real templates. For each
# family, "other" too, it applies the templates in a new git repo with
# hostile sample values: quotes, a backslash, &, |, /, $, and a tab.
#
# Checks for each family:
#   - The file set is the baseline plus the family files.
#   - Each YAML file parses (Ruby) and each JSON file parses. The parsed
#     values equal the parsed template with each {{key}} filled with its
#     sample. So each run: value and each hook value equals the sample.
#   - Each other file equals the template with each {{key}} filled
#     verbatim. Ruby makes the expected text, not the script under test.
#   - flow-template --leftover exits 0.
#   - flow-project-check passes, and flow-project-fact test returns the
#     sample. "other" has no project.md, because the command writes it.
#   - other: .claude/settings.json is the starter templates/settings.json.
#   - flow-baseline --status shows no missing file.
#   - ios-app: the allow rule holds the exact test command.
#
# Control: a copy of flow-template with the escape turned off must fail the
# YAML round trip. The unbroken copy must pass. Set APPLY_NO_CONTROLS=1 to
# skip the controls.
#
# Env override, for the controls:
#   FLOW_BIN  the folder with flow-template, flow-baseline,
#             flow-project-check, and flow-project-fact. The templates
#             folder is next to it.
#
# HERMETIC: each case runs in a throwaway git repo (mktemp -d). No case uses
# the network.
#
# Usage: bash tests/templates/test-apply-families.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# SC2016: the sample values hold $HOME on purpose. It must not expand.
# shellcheck disable=SC2016

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FLOW_BIN="${FLOW_BIN:-$REAL_REPO/plugins/flow/bin}"
TPL="$FLOW_BIN/../templates"
HOST="cloudflare-pages"

TMPROOT="$(cd -P "$(mktemp -d)" && pwd)" || exit 1
TAB="$(printf '\t')"

if command -v ruby >/dev/null 2>&1 && ruby -ryaml -rjson -e 'exit 0' 2>/dev/null \
    && command -v jq >/dev/null 2>&1; then
    pass "ruby with yaml and json, and jq, are available"
else
    fail "ruby with yaml and json, and jq, are available" "install ruby and jq"
    harness_report
fi

# The known keys come from the script, so a new key gets a sample too.
KEYS="$(sed -n 's/^KNOWN_KEYS="\(.*\)"$/\1/p' "$FLOW_BIN/flow-template")"
if [ -n "$KEYS" ]; then
    pass "the script has a KNOWN_KEYS list"
else
    fail "the script has a KNOWN_KEYS list"
    harness_report
fi

# sample <key>: the hostile sample value of a key. It has no backtick,
# because project.md holds the value between backticks.
sample() {
    printf '%s "q" \\ & | / $HOME '"'z'"'%send' "$1" "$TAB"
}

# The samples as JSON for Ruby. --host fills deployment with the host text.
SAMPLES="$TMPROOT/samples.json"
echo '{}' > "$SAMPLES"
for k in $KEYS; do
    [ "$k" = deployment ] && continue
    jq --arg k "$k" --arg v "$(sample "$k")" '.[$k] = $v' "$SAMPLES" > "$SAMPLES.new" && mv "$SAMPLES.new" "$SAMPLES"
done

cat > "$TMPROOT/expect.rb" <<'RUBY'
# expect.rb <samples.json> <deployment-file|-> <baseline-dir> <family-dir|-> <repo>
# Prints one line for each file that is not as expected:
# "yaml <file>: ...", "json <file>: ...", or "text <file>: ...".
require "yaml"
require "json"
Encoding.default_external = "UTF-8"
samples = JSON.parse(File.read(ARGV[0]))
samples["deployment"] = File.read(ARGV[1]).chomp if ARGV[1] != "-"
base, fam, repo = ARGV[2], ARGV[3], ARGV[4]

# Ruby (YAML 1.1) reads the key `on` as true.
def fix(o)
  case o
  when Hash then o.each_with_object({}) { |(k, v), h| h[k == true ? "on" : k.to_s] = fix(v) }
  when Array then o.map { |v| fix(v) }
  else o
  end
end

# "{{" after "$" starts a GitHub expression, not a placeholder.
def fill(s, samples)
  s.gsub(/(?<!\$)\{\{([a-z_]+)\}\}/) { samples.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
end

def deep(o, samples)
  case o
  when Hash then o.each_with_object({}) { |(k, v), h| h[k] = deep(v, samples) }
  when Array then o.map { |v| deep(v, samples) }
  when String then fill(o, samples)
  else o
  end
end

Dir.chdir(repo) do
  Dir.glob("**/*", File::FNM_DOTMATCH).sort.each do |rel|
    next if rel.split("/").include?(".git") || !File.file?(rel)
    src = fam != "-" && File.file?(File.join(fam, rel)) ? File.join(fam, rel) : File.join(base, rel)
    unless File.file?(src)
      puts "text #{rel}: not in the templates"
      next
    end
    text = File.read(src)
    got = File.read(rel)
    case rel
    when /\.ya?ml\z/
      begin
        g = fix(YAML.safe_load(got, aliases: false))
      rescue StandardError, Psych::SyntaxError
        puts "yaml #{rel}: does not parse"
        next
      end
      w = deep(fix(YAML.safe_load(text, aliases: false)), samples)
      puts "yaml #{rel}: the values differ" unless g == w
    when /\.json\z/
      begin
        g = JSON.parse(got)
      rescue JSON::ParserError
        puts "json #{rel}: does not parse"
        next
      end
      puts "json #{rel}: the values differ" unless g == deep(JSON.parse(text), samples)
    else
      puts "text #{rel}: differs" unless got == fill(text, samples)
    end
  end
end
RUBY

# expected_files <family>: the baseline files plus the family files.
expected_files() {
    {
        (cd "$TPL/baseline" && find . -type f ! -name .DS_Store)
        (cd "$TPL/$1" && find . -type f ! -name .DS_Store)
    } | sed 's|^\./||' | LC_ALL=C sort -u
}

families="$("$FLOW_BIN/flow-template" --list)"
if [ "$(printf '%s\n' "$families" | grep -c .)" -eq 6 ]; then
    pass "flow-template --list gives six families"
else
    fail "flow-template --list gives six families" "got: $families"
fi

for F in $families; do
    REPO="$TMPROOT/repo-$F"
    git init -q "$REPO" >/dev/null 2>&1
    cd "$REPO" || exit 1

    args=()
    for k in $KEYS; do
        [ "$k" = deployment ] && continue
        args+=("$k=$(sample "$k")")
    done
    host_file="-"
    if [ "$F" = web-app ]; then
        args+=(--host "$HOST")
        host_file="$TPL/web-app-hosts/$HOST.md"
    fi
    fam_dir="$TPL/$F"

    out="$("$FLOW_BIN/flow-template" --apply "$F" "${args[@]}" 2>&1)"
    rc=$?
    got="$(find . -path ./.git -prune -o -type f -print | sed 's|^\./||' | LC_ALL=C sort)"
    if [ "$rc" -eq 0 ] && [ "$got" = "$(expected_files "$F")" ]; then
        pass "$F: apply exits 0, and the file set is the baseline plus the family"
    else
        fail "$F: apply exits 0, and the file set is the baseline plus the family" "exit: $rc" \
            "$(printf '%s\n' "$out" | tail -3)"
    fi

    res="$(ruby "$TMPROOT/expect.rb" "$SAMPLES" "$host_file" "$TPL/baseline" "$fam_dir" "$REPO" 2>&1)"
    for kind in yaml json text; do
        case "$kind" in
            yaml) label="$F: YAML values round trip" ;;
            json) label="$F: JSON values round trip" ;;
            text) label="$F: other files equal the template with the values verbatim" ;;
        esac
        bad="$(printf '%s\n' "$res" | grep "^$kind ")"
        if [ -z "$bad" ]; then
            pass "$label"
        else
            fail "$label" "$bad"
        fi
    done
    other="$(printf '%s\n' "$res" | grep -vE '^(yaml|json|text) ' | grep .)"
    if [ -z "$other" ]; then
        pass "$F: the Ruby check ran with no error"
    else
        fail "$F: the Ruby check ran with no error" "$other"
    fi

    out="$("$FLOW_BIN/flow-template" --leftover 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
        pass "$F: --leftover exits 0"
    else
        fail "$F: --leftover exits 0" "exit: $rc" "$out"
    fi

    if [ "$F" = other ]; then
        if [ ! -e .claude/project.md ]; then
            pass "$F: no project.md (the command writes it)"
        else
            fail "$F: no project.md (the command writes it)"
        fi
        if cmp -s "$REAL_REPO/templates/settings.json" .claude/settings.json \
            && [ "$(jq -r '.enabledPlugins["flow@devkit"]' .claude/settings.json)" = "true" ]; then
            pass "$F: .claude/settings.json is the starter settings, with flow on"
        else
            fail "$F: .claude/settings.json is the starter settings, with flow on"
        fi
    else
        out="$("$FLOW_BIN/flow-project-check" 2>&1)"
        rc=$?
        fact="$("$FLOW_BIN/flow-project-fact" test 2>&1)"
        # Family A has a fixed test command, not {{test}}.
        if grep -qF '`{{test}}`' "$fam_dir/.claude/project.md"; then
            want="$(sample test)"
        else
            want="$(sed -n 's/^- test: `\(.*\)`$/\1/p' "$fam_dir/.claude/project.md")"
        fi
        if [ "$rc" -eq 0 ] && [ -n "$want" ] && [ "$fact" = "$want" ]; then
            pass "$F: flow-project-check passes, and flow-project-fact test returns the sample or the fixed command"
        else
            fail "$F: flow-project-check passes, and flow-project-fact test returns the sample or the fixed command" \
                "check exit: $rc [$out]" "fact: [$fact]"
        fi
    fi

    out="$("$FLOW_BIN/flow-baseline" --status 2>&1)"
    if ! printf '%s\n' "$out" | grep -q '^missing '; then
        pass "$F: flow-baseline --status shows no missing file"
    else
        fail "$F: flow-baseline --status shows no missing file" "$out"
    fi

    if [ "$F" = ios-app ]; then
        if jq -e --arg r "Bash($(sample test))" '.permissions.allow | index($r)' .claude/settings.json >/dev/null 2>&1; then
            pass "$F: the allow rule holds the exact test command"
        else
            fail "$F: the allow rule holds the exact test command" \
                "$(jq -c '.permissions.allow' .claude/settings.json 2>&1 | tail -c 200)"
        fi
    fi
    cd "$TMPROOT" || exit 1
done

# --- control: the escape turned off --------------------------------------

if [ "${APPLY_NO_CONTROLS:-}" != "1" ]; then
    # run_copy <plugin-copy>: run this script on the copy. Output on stdout.
    run_copy() {
        APPLY_NO_CONTROLS=1 FLOW_BIN="$1/bin" bash "$SELF" 2>&1
    }
    CLEAN="$TMPROOT/plugin-clean"
    mkdir -p "$CLEAN"
    cp -R "$FLOW_BIN" "$CLEAN/bin"
    cp -R "$TPL" "$CLEAN/templates"
    out="$(run_copy "$CLEAN")"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "control clean-copy: the unbroken copy passes"
    else
        fail "control clean-copy: the unbroken copy passes" "$(printf '%s\n' "$out" | grep '^FAIL' | head -5)"
    fi

    NOESC="$TMPROOT/plugin-noesc"
    cp -R "$CLEAN" "$NOESC"
    sed 's/(quote ? esc(val\[key\]) : val\[key\])/val[key]/' "$CLEAN/bin/flow-template" > "$NOESC/bin/flow-template"
    chmod 755 "$NOESC/bin/flow-template"
    out="$(run_copy "$NOESC")"
    rc=$?
    if cmp -s "$CLEAN/bin/flow-template" "$NOESC/bin/flow-template"; then
        fail "control no-escape: the sed changed the script copy"
    elif [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "FAIL: web-app: YAML values round trip" \
        && printf '%s\n' "$out" | grep -qF "FAIL: ios-app: JSON values round trip"; then
        pass "control no-escape: the YAML and JSON round trips fail"
    else
        fail "control no-escape: the YAML and JSON round trips fail" "exit: $rc" \
            "$(printf '%s\n' "$out" | grep '^FAIL' | head -5)"
    fi
fi

harness_report
