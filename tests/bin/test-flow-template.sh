#!/bin/bash
#
# Tests for plugins/flow/bin/flow-template: --list, --apply (the layer
# order, the all-or-nothing check, the symbolic link refusal, the value
# checks, the escapes, --host), --leftover, --pin, and --env-hook. It also
# compares the placeholder list in the script with the "Placeholders" table
# in docs/families.md, both ways, and checks each {{key}} in the templates.
#
# HERMETIC: each case runs in a throwaway git repo (mktemp -d). The script
# reads the real templates. No case uses the network.
#
# Usage: bash tests/bin/test-flow-template.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# SC2016: many strings hold ${{ ... }} or $HOME on purpose. They must not
# expand.
# shellcheck disable=SC2016

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

# The write-failure case makes a folder read-only. Make all of $TMPROOT
# writable again, so rm -rf can remove it.
# shellcheck disable=SC2329 # called only through the EXIT trap
cleanup() {
    cd / || true
    if [ -n "${TMPROOT:-}" ]; then
        chmod -R u+rwx "$TMPROOT" 2>/dev/null
        rm -rf "$TMPROOT"
    fi
}

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-template"
TPL="$REAL_REPO/plugins/flow/templates"
FAMILIES_DOC="$REAL_REPO/docs/families.md"

TMPROOT="$(cd -P "$(mktemp -d)" && pwd)" || exit 1
OUTSIDE="$TMPROOT/outside"
mkdir -p "$OUTSIDE"

SHA="0123456789abcdef0123456789abcdef01234567"
TAB="$(printf '\t')"

# new_repo <name>: make an empty git repo in $TMPROOT and cd into it.
new_repo() {
    REPO="$TMPROOT/$1"
    git init -q "$REPO" >/dev/null 2>&1
    cd "$REPO" || exit 1
}

# run <args...>: run the script. Sets OUT, ERR, RC.
run() {
    OUT="$("$SCRIPT" "$@" 2>"$TMPROOT/stderr")"
    RC=$?
    ERR="$(cat "$TMPROOT/stderr")"
}

# expect_rc <label> <want-rc>
expect_rc() {
    if [ "$RC" -eq "$2" ]; then
        pass "$1"
    else
        fail "$1" "exit: $RC (want $2)" "stdout: [$OUT]" "stderr: [$ERR]"
    fi
}

# tree_files: all files and links in the current repo, except .git.
tree_files() {
    find . -path ./.git -prune -o \( -type f -o -type l \) -print | sed 's|^\./||' | LC_ALL=C sort
}

# expect_no_files <label>: the current repo holds no file.
expect_no_files() {
    if [ -z "$(tree_files)" ]; then
        pass "$1"
    else
        fail "$1" "files: $(tree_files | tr '\n' ' ')"
    fi
}

# template_files <family>: the files that --apply must write, from the
# template folders, sorted.
template_files() {
    {
        (cd "$TPL/baseline" && find . -type f ! -name .DS_Store)
        (cd "$TPL/$1" && find . -type f ! -name .DS_Store)
    } | sed 's|^\./||' | LC_ALL=C sort -u
}

# tree_hash: one hash line for each file in the current repo.
tree_hash() {
    find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s\n' "$(cksum < "$f")" "$f"
    done
}

# --- usage ---------------------------------------------------------------

new_repo usage
for args in "" "--bogus" "--list extra" "--leftover x" "--env-hook x" "--pin $SHA" "--pin" "--apply"; do
    # shellcheck disable=SC2086 # split the arguments on purpose
    run $args
    expect_rc "usage: [${args}] -> 2" 2
done
run --apply web-app --host
expect_rc "usage: --host with no name -> 2" 2
run --apply web-app noequals
expect_rc "usage: a pair with no '=' -> 2" 2
expect_no_files "usage errors write no file"

mkdir -p "$TMPROOT/nogit"
cd "$TMPROOT/nogit" || exit 1
run --apply other
expect_rc "apply outside a git repo -> 2" 2
run --leftover
expect_rc "leftover outside a git repo -> 2" 2

# --- D31: --list ---------------------------------------------------------

run --list
want="ios-app
container-ghcr
web-app
static-site-cloudflare
static-site-host
other"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$want" ]; then
    pass "--list prints the six families in the decision rule order"
else
    fail "--list prints the six families" "exit: $RC" "stdout: [$OUT]"
fi
missing=""
for f in $OUT; do
    [ -d "$TPL/$f" ] || missing="$missing $f"
done
if [ -z "$missing" ]; then
    pass "--list: each family has a template folder"
else
    fail "--list: each family has a template folder" "missing:$missing"
fi

# --- D32-D34: apply order, other, unknown family -------------------------

new_repo order
run --apply static-site-host
ok=1
[ "$RC" -eq 0 ] || ok=0
[ "$(tree_files)" = "$(template_files static-site-host)" ] || ok=0
cmp -s "$TPL/static-site-host/.github/dependabot.yml" .github/dependabot.yml || ok=0
cmp -s "$TPL/static-site-host/.pre-commit-config.yaml" .pre-commit-config.yaml || ok=0
cmp -s "$TPL/baseline/.github/workflows/claude.yml" .github/workflows/claude.yml || ok=0
if [ "$ok" -eq 1 ]; then
    pass "apply: the file set is baseline plus family, and a family file at a baseline path wins"
else
    fail "apply: baseline plus family, family file wins" "exit: $RC" "stderr: [$ERR]" "files: $(tree_files | tr '\n' ' ')"
fi
if [ -z "$(find . -name '.flow-template.*' -print)" ]; then
    pass "apply leaves no temp file"
else
    fail "apply leaves no temp file" "$(find . -name '.flow-template.*' -print)"
fi
if [ -z "$(git status --porcelain --untracked-files=no)" ] && [ -z "$(git diff --cached --name-only)" ]; then
    pass "apply does not change the git index"
else
    fail "apply does not change the git index" "$(git status --porcelain)"
fi
mode_bad=""
while IFS= read -r f; do
    [ -n "$(find "$f" -perm 644)" ] || mode_bad="$mode_bad $f"
done <<EOF
$(tree_files)
EOF
if [ -z "$mode_bad" ]; then
    pass "apply: each file is mode 0644"
else
    fail "apply: each file is mode 0644" "bad:$mode_bad"
fi

new_repo other
run --apply other
if [ "$RC" -eq 0 ] && [ "$(tree_files)" = "$(template_files other)" ] \
    && cmp -s "$REAL_REPO/templates/settings.json" .claude/settings.json; then
    pass "apply other: the baseline files and the starter .claude/settings.json"
else
    fail "apply other: the baseline files and the starter .claude/settings.json" "exit: $RC" "files: $(tree_files | tr '\n' ' ')"
fi

# rm of a temp file fails after ln: an rm stub fails on the first try for
# each temp file. The EXIT trap must try again, so no temp file stays.
RM_BIN="$TMPROOT/rm-bin"
RM_SEEN="$TMPROOT/rm-seen"
mkdir -p "$RM_BIN" "$RM_SEEN"
cat > "$RM_BIN/rm" <<EOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        */.flow-template.*)
            m="$RM_SEEN/\$(basename "\$a")"
            if [ ! -e "\$m" ]; then
                : > "\$m"
                exit 1
            fi
            ;;
    esac
done
exec "$(command -v rm)" "\$@"
EOF
chmod 755 "$RM_BIN/rm"
new_repo rmfail
OUT="$(PATH="$RM_BIN:$PATH" "$SCRIPT" --apply other 2>"$TMPROOT/stderr")"
RC=$?
ERR="$(cat "$TMPROOT/stderr")"
if [ "$RC" -eq 0 ] && [ -z "$(find . -name '.flow-template.*' -print)" ] \
    && [ -n "$(find "$RM_SEEN" -type f -print)" ] && printf '%s' "$ERR" | grep -qF "warning: could not remove"; then
    pass "apply: an rm failure after ln warns, and the EXIT trap removes the temp file"
else
    fail "apply: an rm failure after ln warns, and the EXIT trap removes the temp file" "exit: $RC" \
        "stderr: [$ERR]" "left: $(find . -name '.flow-template.*' -print | tr '\n' ' ')"
fi

# rm of a temp file fails each time, also in the EXIT trap. The temp files
# stay, so the run is not complete: exit 3, with the Wrote: list.
RM_ALL_BIN="$TMPROOT/rm-all-bin"
mkdir -p "$RM_ALL_BIN"
cat > "$RM_ALL_BIN/rm" <<EOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        */.flow-template.*) exit 1 ;;
    esac
done
exec "$(command -v rm)" "\$@"
EOF
chmod 755 "$RM_ALL_BIN/rm"
new_repo rmalways
OUT="$(PATH="$RM_ALL_BIN:$PATH" "$SCRIPT" --apply other 2>"$TMPROOT/stderr")"
RC=$?
ERR="$(cat "$TMPROOT/stderr")"
if [ "$RC" -eq 3 ] && printf '%s' "$ERR" | grep -qF "temp files stay:" \
    && printf '%s' "$ERR" | grep -qF "Wrote: .claude/settings.json"; then
    pass "apply: temp files that stay at exit -> 3, with the Wrote: list"
else
    fail "apply: temp files that stay at exit -> 3, with the Wrote: list" "exit: $RC" "stderr: [$ERR]"
fi
find . -name '.flow-template.*' -exec rm -f {} + 2>/dev/null

new_repo unknownfamily
for fam in bogus web-app-hosts baseline ../templates; do
    run --apply "$fam"
    expect_rc "apply of family [$fam] -> 2" 2
done
expect_no_files "an unknown family writes no file"

# --- D35: all-or-nothing -------------------------------------------------

new_repo late
# CLAUDE.md sorts last, so a check that stops at the first write would
# write all the other files first.
printf 'mine\n' > CLAUDE.md
run --apply web-app
expect_rc "apply with one late conflict -> 1" 1
if [ "$(tree_files)" = "CLAUDE.md" ] && [ "$(cat CLAUDE.md)" = "mine" ] \
    && printf '%s' "$ERR" | grep -qF "wrote no file"; then
    pass "one late conflict: nothing is written, the file stays"
else
    fail "one late conflict: nothing is written" "files: $(tree_files | tr '\n' ' ')" "stderr: [$ERR]"
fi

new_repo blocked
printf 'a file\n' > .github
run --apply other
expect_rc "apply when a file blocks a parent folder -> 1" 1
if [ "$(tree_files)" = ".github" ]; then
    pass "blocked parent: nothing is written"
else
    fail "blocked parent: nothing is written" "files: $(tree_files | tr '\n' ' ')"
fi

# --- D36: symbolic links -------------------------------------------------

new_repo filelink
printf 'outside\n' > "$OUTSIDE/target"
ln -s "$OUTSIDE/target" .pre-commit-config.yaml
run --apply other
expect_rc "apply with a file link at a target -> 1" 1
if [ "$(cat "$OUTSIDE/target")" = "outside" ] && [ "$(tree_files)" = ".pre-commit-config.yaml" ]; then
    pass "file link: nothing is written, the outside file stays"
else
    fail "file link: nothing is written" "files: $(tree_files | tr '\n' ' ')"
fi

new_repo danglink
ln -s "$OUTSIDE/no-such-file" .pre-commit-config.yaml
run --apply other
expect_rc "apply with a dangling link at a target -> 1" 1
if [ ! -e "$OUTSIDE/no-such-file" ] && [ "$(tree_files)" = ".pre-commit-config.yaml" ]; then
    pass "dangling link: nothing is written outside the repo"
else
    fail "dangling link: nothing is written outside the repo" "files: $(tree_files | tr '\n' ' ')"
fi

new_repo dirlink
mkdir -p "$OUTSIDE/gh"
ln -s "$OUTSIDE/gh" .github
run --apply other
expect_rc "apply with a .github folder link -> 1" 1
if [ -z "$(find "$OUTSIDE/gh" -mindepth 1 -print)" ] && [ "$(tree_files)" = ".github" ]; then
    pass "folder link: nothing is written through it"
else
    fail "folder link: nothing is written through it" "$(find "$OUTSIDE/gh" -print)"
fi

# --- D37: read-only folder -----------------------------------------------

if [ "$IS_ROOT" -eq 1 ]; then
    pass "apply: write failure: skipped as root"
else
    new_repo readonly
    mkdir .github
    chmod 555 .github
    run --apply web-app
    chmod 755 .github
    if [ "$RC" -eq 3 ] \
        && printf '%s' "$ERR" | grep -qF "could not write .github/" \
        && printf '%s' "$ERR" | grep -qF "Wrote: .claude/hooks/block-env.sh, " \
        && [ -f .claude/project.md ] && [ ! -e CLAUDE.md ]; then
        pass "apply: a read-only folder -> 3, stderr names the written files"
    else
        fail "apply: a read-only folder -> 3" "exit: $RC" "stderr: [$ERR]" "files: $(tree_files | tr '\n' ' ')"
    fi
    if [ -z "$(find . -name '.flow-template.*' -print)" ]; then
        pass "apply: a write failure leaves no temp file"
    else
        fail "apply: a write failure leaves no temp file" "$(find . -name '.flow-template.*' -print)"
    fi
fi

# --- D38-D40: subfolder, spaces, hidden files ----------------------------

new_repo subfolder
mkdir -p sub/dir
cd sub/dir || exit 1
run --apply other
cd "$REPO" || exit 1
if [ "$RC" -eq 0 ] && [ "$(tree_files)" = "$(template_files other)" ]; then
    pass "apply from a subfolder writes at the repo root"
else
    fail "apply from a subfolder writes at the repo root" "exit: $RC" "files: $(tree_files | tr '\n' ' ')"
fi

new_repo "with space/repo dir"
run --apply ios-app app_name="My App"
if [ "$RC" -eq 0 ] && [ "$(tree_files)" = "$(template_files ios-app)" ] \
    && head -n 1 CLAUDE.md | grep -qxF "# CLAUDE.md — My App"; then
    pass "apply in a repo path with spaces"
else
    fail "apply in a repo path with spaces" "exit: $RC" "stderr: [$ERR]"
fi

hidden="$(template_files container-ghcr | grep -E '(^|/)\.' | grep -c .)"
new_repo hidden
run --apply container-ghcr
got="$(tree_files | grep -E '(^|/)\.' | grep -c .)"
if [ "$RC" -eq 0 ] && [ "$hidden" -ge 5 ] && [ "$got" = "$hidden" ] \
    && [ -f .dockerignore ] && [ -f .gitignore ] && [ -f .pre-commit-config.yaml ]; then
    pass "apply copies the hidden files ($got)"
else
    fail "apply copies the hidden files" "want: $hidden, got: $got"
fi
expect_mode=""
new_repo webmode
run --apply web-app
[ -n "$(find .claude/hooks/block-env.sh -perm 755)" ] || expect_mode="block-env.sh"
[ -n "$(find CLAUDE.md -perm 644)" ] || expect_mode="$expect_mode CLAUDE.md"
if [ "$RC" -eq 0 ] && [ -z "$expect_mode" ]; then
    pass "apply keeps the exec bit: block-env.sh 0755, other files 0644"
else
    fail "apply keeps the exec bit" "exit: $RC" "bad: $expect_mode"
fi

# --- D41: refused values -------------------------------------------------

# refuse <label> <message-part> <args...>: the apply must exit 1, write no
# file, and name the problem on stderr.
refuse() {
    local label="$1" msg="$2"
    shift 2
    new_repo "refuse-$(printf '%s' "$label" | tr -c 'a-z0-9' '-')"
    run --apply web-app "$@"
    if [ "$RC" -eq 1 ] && [ -z "$(tree_files)" ] && printf '%s' "$ERR" | grep -qF -- "$msg"; then
        pass "refused, exit 1, no file: $label"
    else
        fail "refused, exit 1, no file: $label" "exit: $RC" "stderr: [$ERR]" "files: $(tree_files | tr '\n' ' ')"
    fi
}
refuse "unknown key" "not a known placeholder" bogus=1
refuse "GitHub expression" "GitHub expression" 'test=echo ${{ secrets.TOKEN }}'
refuse "GitHub expression with no space" "GitHub expression" 'lint=x${{github.ref}}'
refuse "newline" "newline" "test=make
rm -rf /"
refuse "placeholder in a value" "has '{{'" 'test={{lint}}'
refuse "open braces only" "has '{{'" 'test=a {{ b'
refuse "key named two times" "two times" test=a test=b
refuse "deployment and --host" "not both" --host cloudflare-pages deployment=x
refuse "one bad value among good values" "GitHub expression" test=ok lint=ok 'verify=${{ x }}'
# A command value makes the allow rule Bash(<value>). Claude Code reads a
# * at any position in the rule as a wildcard.
refuse "test is *" "has '*'" 'test=*'
refuse "lint ends in :*" "has '*'" 'lint=npm run:*'
refuse "test_quick ends in :*" "has '*'" 'test_quick=x:*'
refuse "typecheck is *" "has '*'" 'typecheck=*'
refuse "verify ends in :*" "has '*'" 'verify=make:*'
refuse "test is space-star" "has '*'" 'test= *'
refuse "test is star-tab" "has '*'" "test=*${TAB}"
refuse "test is **" "has '*'" 'test=**'
refuse "lint is :* with a space" "has '*'" 'lint=:* '
refuse "test ends in space-star" "has '*'" 'test=xcodebuild test *'
refuse "verify has a star inside" "has '*'" 'verify=a*b'
refuse "test starts with a space" "starts or ends with a space or tab" 'test= npm test'
refuse "lint ends with a tab" "starts or ends with a space or tab" "lint=npm run lint${TAB}"
refuse "test is empty" "is empty" 'test='
refuse "verify is empty" "is empty" 'verify='

# Control: the * rule is only for the command keys.
new_repo star-ok
run --apply web-app 'app_name=*' 'app_description=a * b' 'test=npm test'
if [ "$RC" -eq 0 ] && grep -qxF -- '# CLAUDE.md — *' CLAUDE.md && grep -qxF -- 'a * b' CLAUDE.md; then
    pass "control: a * in a key that is not a command is accepted"
else
    fail "control: a * in a key that is not a command is accepted" "exit: $RC" "stderr: [$ERR]"
fi

# --- D42: Markdown is verbatim -------------------------------------------

HOSTILE='a&b /c|d \e $HOME `f` "g" '"'h'"' \1 &amp;'
new_repo markdown
run --apply container-ghcr "app_name=$HOSTILE" "test=$HOSTILE"
if [ "$RC" -eq 0 ] && [ "$(head -n 1 CLAUDE.md)" = "# CLAUDE.md — $HOSTILE" ] \
    && grep -qxF -- "- test: \`$HOSTILE\`" .claude/project.md; then
    pass "Markdown: a value with & / | \\ \$ backtick and quotes is verbatim"
else
    fail "Markdown: value is verbatim" "exit: $RC" "line 1: [$(head -n 1 CLAUDE.md)]" "stderr: [$ERR]"
fi

# --- D43: YAML round trip ------------------------------------------------

YVAL='make "t" \ & | / $HOME `x` '"'q'${TAB}end"' \n'
new_repo yaml
run --apply web-app "test=$YVAL" "lint=$YVAL" "typecheck=$YVAL" "test_quick=$YVAL"
if command -v ruby >/dev/null 2>&1 && ruby -ryaml -rjson -e 'exit 0' 2>/dev/null; then
    # shellcheck disable=SC2016 # Ruby code
    got="$(ruby -ryaml -rjson -e '
        ci = YAML.safe_load(File.read(".github/workflows/ci.yml"))
        pc = YAML.safe_load(File.read(".pre-commit-config.yaml"))
        runs = ci["jobs"].values.flat_map { |j| j["steps"] }.map { |s| s["run"] }.compact
        args = pc["repos"].select { |r| r["repo"] == "local" }.flat_map { |r| r["hooks"] }.map { |h| h["args"].last }
        puts JSON.generate(runs + args)' 2>&1)"
    want="$(jq -cn --arg v "$YVAL" '[$v, $v, $v, $v]')"
    if [ "$RC" -eq 0 ] && [ "$got" = "$want" ]; then
        pass "YAML: the parsed run: and hook values equal the value (quotes, backslash, tab)"
    else
        fail "YAML: parsed values equal the value" "exit: $RC" "got:  [$got]" "want: [$want]"
    fi
else
    fail "YAML: ruby with yaml and json is available"
fi

# --- D44: JSON round trip ------------------------------------------------

JVAL='xcodebuild test -scheme "A\"B" \x'"${TAB}"'tab"), "Bash(rm:x)'
new_repo json
run --apply ios-app "test=$JVAL"
got="$(jq -r --arg v "Bash($JVAL)" '[.permissions.allow[] | select(. == $v)] | length' .claude/settings.json 2>&1)"
n_src="$(jq '.permissions.allow | length' "$TPL/ios-app/.claude/settings.json")"
n_got="$(jq '.permissions.allow | length' .claude/settings.json 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ "$got" = "1" ] && [ "$n_got" = "$n_src" ] \
    && ! jq -e '.permissions.allow | index("Bash(rm:x)")' .claude/settings.json >/dev/null; then
    pass "JSON: the allow rule holds the exact value, with a tab, and adds no rule"
else
    fail "JSON: the allow rule holds the exact value" "exit: $RC" "match: [$got]" "rules: $n_got (want $n_src)" "stderr: [$ERR]"
fi
CVAL="a$(printf '\001')b"
new_repo jsonctl
run --apply ios-app "test=$CVAL"
if [ "$RC" -eq 0 ] && jq -e --arg v "Bash($CVAL)" '.permissions.allow | index($v)' .claude/settings.json >/dev/null 2>&1 \
    && grep -qF 'a\u0001b' .claude/settings.json; then
    pass "JSON: a control character gets a \\u escape"
else
    fail "JSON: a control character gets a \\u escape" "exit: $RC" "$(grep -F 'Bash(a' .claude/settings.json)"
fi
DVAL="a$(printf '\177')b"
new_repo jsondel
run --apply ios-app "test=$DVAL"
if [ "$RC" -eq 0 ] && jq -e --arg v "Bash($DVAL)" '.permissions.allow | index($v)' .claude/settings.json >/dev/null 2>&1 \
    && grep -qF 'a\u007fb' .claude/settings.json; then
    pass "JSON: DEL gets a \\u007f escape"
else
    fail "JSON: DEL gets a \\u007f escape" "exit: $RC" "$(grep -F 'Bash(a' .claude/settings.json | od -c | head -3)"
fi

# --- D45: GitHub expressions stay ----------------------------------------

new_repo gha
run --apply container-ghcr test=t lint=l test_quick=q stack_ecosystem=npm
bad=""
for rel in .github/workflows/ci.yml .github/workflows/container-image.yml .github/workflows/claude.yml .github/workflows/claude-code-review.yml; do
    src="$TPL/container-ghcr/$rel"
    [ -f "$src" ] || src="$TPL/baseline/$rel"
    [ "$(grep -F '${{' "$src")" = "$(grep -F '${{' "$rel")" ] || bad="$bad $rel"
    grep -qF '${{' "$src" || bad="$bad $rel(no expression in the template)"
done
cmp -s "$TPL/container-ghcr/.github/workflows/container-image.yml" .github/workflows/container-image.yml || bad="$bad container-image.yml(bytes)"
if [ "$RC" -eq 0 ] && [ -z "$bad" ]; then
    pass "each \${{ ... }} line stays byte-identical"
else
    fail "each \${{ ... }} line stays byte-identical" "exit: $RC" "bad:$bad"
fi

# No real template has a known key inside ${{ }}, so a fixture in a copy of
# the plugin checks that case.
GPLUGIN="$TMPROOT/gplugin"
mkdir -p "$GPLUGIN/bin"
cp "$SCRIPT" "$GPLUGIN/bin/flow-template"
cp -R "$TPL" "$GPLUGIN/templates"
printf 'a: "${{test}}" "{{test}}" "x}}{{test}}"\n' > "$GPLUGIN/templates/baseline/gha.yml"
new_repo ghakey
OUT="$("$GPLUGIN/bin/flow-template" --apply other test=V 2>"$TMPROOT/stderr")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat gha.yml)" = 'a: "${{test}}" "V" "x}}V"' ]; then
    pass "a {{key}} right after \$ stays, as a GitHub expression"
else
    fail "a {{key}} right after \$ stays" "exit: $RC" "got: [$(cat gha.yml 2>&1)]"
fi

# --- D46: --host ---------------------------------------------------------

for h in cloudflare-pages a2-tag; do
    new_repo "host-$h"
    run --apply web-app --host "$h"
    n="$(grep -n '^{{deployment}}$' "$TPL/web-app/CLAUDE.md" | cut -d: -f1)"
    {
        head -n "$((n - 1))" "$TPL/web-app/CLAUDE.md"
        cat "$TPL/web-app-hosts/$h.md"
        tail -n "+$((n + 1))" "$TPL/web-app/CLAUDE.md"
    } > "$TMPROOT/want-claude.md"
    if [ "$RC" -eq 0 ] && [ -n "$n" ] && cmp -s "$TMPROOT/want-claude.md" CLAUDE.md; then
        pass "--host $h: the host text is in place of {{deployment}}"
    else
        fail "--host $h: the host text is in place of {{deployment}}" "exit: $RC" \
            "$(diff "$TMPROOT/want-claude.md" CLAUDE.md | head -5)"
    fi
done
new_repo hostbad
for h in bogus ../web-app/CLAUDE "" A2-TAG; do
    run --apply web-app --host "$h"
    expect_rc "--host [$h] -> 2" 2
done
run --apply ios-app --host cloudflare-pages
expect_rc "--host with a family other than web-app -> 2" 2
run --apply web-app --host a2-tag --host cloudflare-pages
expect_rc "--host two times -> 2" 2
expect_no_files "a bad --host writes no file"

# An unreadable host file: a copy of the plugin, so the real template keeps
# its mode.
if [ "$IS_ROOT" -eq 1 ]; then
    pass "--host: unreadable host file: skipped as root"
else
    HPLUGIN="$TMPROOT/hplugin"
    mkdir -p "$HPLUGIN/bin"
    cp "$SCRIPT" "$HPLUGIN/bin/flow-template"
    cp -R "$TPL" "$HPLUGIN/templates"
    chmod 000 "$HPLUGIN/templates/web-app-hosts/a2-tag.md"
    new_repo hostunread
    OUT="$("$HPLUGIN/bin/flow-template" --apply web-app --host a2-tag 2>"$TMPROOT/stderr")"
    RC=$?
    ERR="$(cat "$TMPROOT/stderr")"
    if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF "cannot read" && [ -z "$(tree_files)" ]; then
        pass "--host with an unreadable host file -> 2, no file"
    else
        fail "--host with an unreadable host file -> 2, no file" "exit: $RC" "stderr: [$ERR]" "files: $(tree_files | tr '\n' ' ')"
    fi
    # The awk fill also stops on a read error, so an empty {{deployment}}
    # cannot pass. A copy with no -r check gets to the awk read.
    sed 's/if \[ ! -r "\$host_file" \]; then/if false; then/' "$SCRIPT" > "$HPLUGIN/bin/flow-template"
    new_repo hostunread-awk
    OUT="$("$HPLUGIN/bin/flow-template" --apply web-app --host a2-tag 2>"$TMPROOT/stderr")"
    RC=$?
    ERR="$(cat "$TMPROOT/stderr")"
    if cmp -s "$SCRIPT" "$HPLUGIN/bin/flow-template"; then
        fail "--host: the sed removed the -r check in the copy"
    elif [ "$RC" -eq 3 ] && printf '%s' "$ERR" | grep -qF "could not write "; then
        pass "--host: an awk read error of the host file -> 3, not an empty {{deployment}}"
    else
        fail "--host: an awk read error of the host file -> 3" "exit: $RC" "stderr: [$ERR]"
    fi
    chmod 644 "$HPLUGIN/templates/web-app-hosts/a2-tag.md"
fi

# --- D47: second apply ---------------------------------------------------

new_repo second
run --apply web-app test=t
before="$(tree_hash)"
run --apply web-app test=other
expect_rc "second apply -> 1" 1
if [ "$(tree_hash)" = "$before" ]; then
    pass "second apply changes no file"
else
    fail "second apply changes no file"
fi

# --- D48: --leftover -----------------------------------------------------

new_repo leftover
run --leftover
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "--leftover on a clean repo: silent, exit 0"
else
    fail "--leftover on a clean repo: silent, exit 0" "exit: $RC" "stdout: [$OUT]"
fi
mkdir -p docs "a b" node_modules/pkg .github/workflows
printf 'line one\nRun {{test}} and {{lint}}.\n' > docs/x.md
printf 'v: "${{ github.ref }}"\nw: ${{test}}\nz: "{{stack_ecosystem}}"\n' > .github/workflows/ci.yml
printf '{{unknown}} {{ test }} {test} {{test\n' > "a b/c d.txt"
printf '{{test}}\n' > node_modules/pkg/README.md
printf '{{test}}\n' > .git/description
run --leftover
# "a b/c d.txt" holds only text that is not a known {{key}}.
got="$(printf '%s\n' "$OUT" | LC_ALL=C sort)"
want="$(printf '%s\n' ".github/workflows/ci.yml:3: {{stack_ecosystem}}" "docs/x.md:2: {{test}}" "docs/x.md:2: {{lint}}" | LC_ALL=C sort)"
if [ "$RC" -eq 1 ] && [ "$got" = "$want" ]; then
    pass "--leftover lists file:line: {{key}}, skips \${{, unknown keys, node_modules, and .git"
else
    fail "--leftover lists the placeholders" "exit: $RC" "got:  [$got]" "want: [$want]"
fi

# --- D49: --pin ----------------------------------------------------------

new_repo pin
run --apply other
mkdir -p .github/workflows
cat > .github/workflows/extra.yml <<'EOF'
jobs:
  a:
    uses: unibrain1/devkit/.github/workflows/node-site.yml@main
  b:
    uses: other/devkit/.github/workflows/x.yml@main
    # uses: unibrain1/devkit/.github/workflows/x.yml@main is only text
  c:
    steps:
      - uses: actions/checkout@main
      - uses: unibrain1/devkit/actions/setup@main
EOF
cp .github/workflows/extra.yml "$TMPROOT/extra.before"
printf 'uses: unibrain1/devkit/x.yml@main\n' > .github/workflows/other.yaml
before="$(tree_hash)"
for bad in "0123456789ABCDEF0123456789abcdef01234567 v1.2.3" "${SHA%7} v1.2.3" "${SHA}8 v1.2.3" \
    "0123456789abcdef0123456789abcdef0123456g v1.2.3" "$SHA 1.2.3" "$SHA v1.2" "$SHA v1.2.3-rc1" "$SHA main" "$SHA v1.2.3x"; do
    # shellcheck disable=SC2086 # split the arguments on purpose
    run --pin $bad
    expect_rc "--pin [$bad] -> 2" 2
done
run --pin "$SHA
" v1.2.3
expect_rc "--pin with a newline in the SHA -> 2" 2
if [ "$(tree_hash)" = "$before" ]; then
    pass "a bad --pin changes no file"
else
    fail "a bad --pin changes no file"
fi
run --pin "$SHA" v1.2.3
want_extra="$(sed -e "s|node-site.yml@main\$|node-site.yml@$SHA # v1.2.3|" \
    -e "s|devkit/actions/setup@main\$|devkit/actions/setup@$SHA # v1.2.3|" "$TMPROOT/extra.before")"
pinned=0
for f in claude.yml claude-code-review.yml secrets-scan.yml; do
    grep -qE "^    uses: unibrain1/devkit/\.github/workflows/[a-z-]+\.yml@$SHA # v1\.2\.3\$" ".github/workflows/$f" && pinned=$((pinned + 1))
done
if [ "$RC" -eq 0 ] && [ "$pinned" -eq 3 ] && [ "$(cat .github/workflows/extra.yml)" = "$want_extra" ] \
    && [ "$(cat .github/workflows/other.yaml)" = "uses: unibrain1/devkit/x.yml@$SHA # v1.2.3" ] \
    && ! grep -rqF 'unibrain1/devkit/.github/workflows/claude.yml@main' .github/workflows; then
    pass "--pin changes only the unibrain1/devkit uses: lines in .github/workflows/*.yml and *.yaml"
else
    fail "--pin changes only the devkit lines" "exit: $RC" "stderr: [$ERR]" "$(diff "$TMPROOT/extra.before" .github/workflows/extra.yml)"
fi
before="$(tree_hash)"
run --pin "$SHA" v1.2.3
if [ "$RC" -eq 0 ] && [ "$(tree_hash)" = "$before" ]; then
    pass "--pin second run: no change, exit 0"
else
    fail "--pin second run: no change" "exit: $RC" "stdout: [$OUT]"
fi
new_repo pinlink
mkdir -p .github/workflows
printf 'jobs:\n  a:\n    uses: unibrain1/devkit/x.yml@main\n' > "$OUTSIDE/linked.yml"
ln -s "$OUTSIDE/linked.yml" .github/workflows/linked.yml
run --pin "$SHA" v1.2.3
if [ "$RC" -eq 1 ] && grep -qF '@main' "$OUTSIDE/linked.yml"; then
    pass "--pin refuses a workflow file that is a link, exit 1"
else
    fail "--pin refuses a workflow file that is a link" "exit: $RC"
fi

new_repo pindangle
mkdir -p .github/workflows
ln -s "$OUTSIDE/no-such-workflow.yml" .github/workflows/dangle.yml
run --pin "$SHA" v1.2.3
if [ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -qF "symbolic link" && [ ! -e "$OUTSIDE/no-such-workflow.yml" ]; then
    pass "--pin refuses a dangling workflow link, exit 1"
else
    fail "--pin refuses a dangling workflow link, exit 1" "exit: $RC" "stdout: [$OUT]" "stderr: [$ERR]"
fi

if [ "$IS_ROOT" -eq 1 ]; then
    pass "--pin: unreadable workflow file: skipped as root"
else
    new_repo pinunread
    mkdir -p .github/workflows
    printf 'jobs:\n  a:\n    uses: unibrain1/devkit/x.yml@main\n' > .github/workflows/a.yml
    chmod 000 .github/workflows/a.yml
    run --pin "$SHA" v1.2.3
    chmod 644 .github/workflows/a.yml
    if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF "cannot read" && grep -qF '@main' .github/workflows/a.yml; then
        pass "--pin with an unreadable workflow file -> 2, no change"
    else
        fail "--pin with an unreadable workflow file -> 2, no change" "exit: $RC" "stdout: [$OUT]" "stderr: [$ERR]"
    fi
fi

if [ "$IS_ROOT" -eq 1 ]; then
    pass "--pin: unreadable workflow folder: skipped as root"
else
    new_repo pinunreaddir
    mkdir -p .github/workflows
    printf 'jobs:\n  a:\n    uses: unibrain1/devkit/x.yml@main\n' > .github/workflows/a.yml
    chmod 000 .github/workflows
    run --pin "$SHA" v1.2.3
    chmod 755 .github/workflows
    if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF "cannot read" && grep -qF '@main' .github/workflows/a.yml; then
        pass "--pin with an unreadable workflow folder -> 2, no change"
    else
        fail "--pin with an unreadable workflow folder -> 2, no change" "exit: $RC" "stdout: [$OUT]" "stderr: [$ERR]"
    fi
fi

# A link that appears after the first check: a sed stub runs the real sed,
# then puts a link to an outside folder at .github/workflows.
RACE_BIN="$TMPROOT/race-bin"
RACE_OUT="$OUTSIDE/race-wf"
mkdir -p "$RACE_BIN"
cat > "$RACE_BIN/sed" <<EOF
#!/bin/bash
"$(command -v sed)" "\$@" || exit \$?
top="\$(git rev-parse --show-toplevel)"
mkdir -p "$RACE_OUT"
cp -R "\$top/.github/workflows/." "$RACE_OUT/"
mv "\$top/.github/workflows" "\$top/.github/wf-real"
ln -s "$RACE_OUT" "\$top/.github/workflows"
EOF
chmod 755 "$RACE_BIN/sed"
new_repo pinrace
mkdir -p .github/workflows
printf 'jobs:\n  a:\n    uses: unibrain1/devkit/x.yml@main\n' > .github/workflows/a.yml
OUT="$(PATH="$RACE_BIN:$PATH" "$SCRIPT" --pin "$SHA" v1.2.3 2>"$TMPROOT/stderr")"
RC=$?
ERR="$(cat "$TMPROOT/stderr")"
if [ "$RC" -eq 3 ] && printf '%s' "$ERR" | grep -qF "symbolic link" && grep -qF '@main' "$RACE_OUT/a.yml"; then
    pass "--pin: a link that appears before the write stops it, exit 3"
else
    fail "--pin: a link that appears before the write stops it, exit 3" "exit: $RC" "stderr: [$ERR]" \
        "outside: $(cat "$RACE_OUT/a.yml" 2>&1)"
fi

# --- D50: --env-hook -----------------------------------------------------

HOOK_SRC="$TPL/web-app/.claude/hooks/block-env.sh"
ENTRY="$(jq -c '.hooks.PreToolUse[0]' "$TPL/web-app/.claude/settings.json")"

new_repo envnew
run --env-hook
if [ "$RC" -eq 0 ] && cmp -s "$HOOK_SRC" .claude/hooks/block-env.sh \
    && [ -n "$(find .claude/hooks/block-env.sh -perm 755)" ] \
    && [ "$(jq -c . .claude/settings.json)" = "$(jq -cn --argjson e "$ENTRY" '{hooks: {PreToolUse: [$e]}}')" ]; then
    pass "--env-hook in a new repo: hook mode 0755, a valid settings.json with the entry"
else
    fail "--env-hook in a new repo" "exit: $RC" "stderr: [$ERR]"
fi

new_repo envmerge
mkdir -p .claude
cat > .claude/settings.json <<'EOF'
{
  "permissions": { "allow": ["Bash(ls:*)"] },
  "hooks": {
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo mine" } ] } ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "echo stop" } ] } ]
  }
}
EOF
cp .claude/settings.json "$TMPROOT/settings.before"
run --env-hook
want="$(jq -S --argjson e "$ENTRY" '.hooks.PreToolUse += [$e]' "$TMPROOT/settings.before")"
if [ "$RC" -eq 0 ] && [ "$(jq -S . .claude/settings.json)" = "$want" ]; then
    pass "--env-hook merges the entry and keeps the other keys and hooks"
else
    fail "--env-hook merges the entry" "exit: $RC" "stderr: [$ERR]" "$(jq -c . .claude/settings.json)"
fi
before="$(tree_hash)"
run --env-hook
if [ "$RC" -eq 0 ] && [ "$(tree_hash)" = "$before" ]; then
    pass "--env-hook second run: no change, exit 0"
else
    fail "--env-hook second run: no change" "exit: $RC" "stderr: [$ERR]"
fi

new_repo envother
run --apply other
cp .claude/settings.json "$TMPROOT/other-settings.before"
run --env-hook
want="$(jq -S --argjson e "$ENTRY" '.hooks.PreToolUse = [$e]' "$TMPROOT/other-settings.before")"
if [ "$RC" -eq 0 ] && [ "$(jq -S . .claude/settings.json)" = "$want" ] \
    && [ "$(jq -r '.enabledPlugins["flow@devkit"]' .claude/settings.json)" = "true" ]; then
    pass "--env-hook after apply other: merges into the copied settings.json, flow stays on"
else
    fail "--env-hook after apply other: merges into the copied settings.json" "exit: $RC" "stderr: [$ERR]"
fi

new_repo envapplied
run --apply web-app
before="$(tree_hash)"
run --env-hook
if [ "$RC" -eq 0 ] && [ "$(tree_hash)" = "$before" ]; then
    pass "--env-hook after apply web-app: no change"
else
    fail "--env-hook after apply web-app: no change" "exit: $RC" "stderr: [$ERR]"
fi

new_repo envbad
mkdir -p .claude
printf '{ "a": \n' > .claude/settings.json
cp .claude/settings.json "$TMPROOT/bad.before"
run --env-hook
if [ "$RC" -eq 1 ] && cmp -s "$TMPROOT/bad.before" .claude/settings.json && [ ! -e .claude/hooks ]; then
    pass "--env-hook with a bad settings.json: exit 1, no change"
else
    fail "--env-hook with a bad settings.json: exit 1, no change" "exit: $RC" "files: $(tree_files | tr '\n' ' ')"
fi
printf '[1, 2]\n' > .claude/settings.json
run --env-hook
expect_rc "--env-hook with a settings.json that is not an object -> 1" 1
printf '{"hooks": {"PreToolUse": {}}}\n' > .claude/settings.json
run --env-hook
expect_rc "--env-hook with a PreToolUse that is not an array -> 1" 1

new_repo envdiff
mkdir -p .claude/hooks
printf '#!/bin/bash\nexit 0\n' > .claude/hooks/block-env.sh
printf '{"model": "x"}\n' > .claude/settings.json
before="$(tree_hash)"
run --env-hook
if [ "$RC" -eq 1 ] && [ "$(tree_hash)" = "$before" ]; then
    pass "--env-hook with a different block-env.sh: exit 1, no change"
else
    fail "--env-hook with a different block-env.sh" "exit: $RC"
fi

new_repo envlink
mkdir -p .claude
printf '{}\n' > "$OUTSIDE/settings.json"
ln -s "$OUTSIDE/settings.json" .claude/settings.json
run --env-hook
if [ "$RC" -eq 1 ] && [ "$(cat "$OUTSIDE/settings.json")" = "{}" ] && [ ! -e .claude/hooks ]; then
    pass "--env-hook refuses a settings.json link, exit 1"
else
    fail "--env-hook refuses a settings.json link" "exit: $RC"
fi

# No jq: a PATH with only the tools that the script needs before it checks
# for jq. /usr/bin can hold jq, so the case cannot use it.
NOJQ="$TMPROOT/nojq-bin"
mkdir -p "$NOJQ"
for t in git basename dirname cat rm mktemp readlink; do
    p="$(command -v "$t")" && ln -s "$p" "$NOJQ/$t"
done
new_repo envnojq
OUT="$(PATH="$NOJQ" /bin/bash "$SCRIPT" --env-hook 2>"$TMPROOT/stderr")"
RC=$?
ERR="$(cat "$TMPROOT/stderr")"
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF "jq" && [ -z "$(tree_files)" ]; then
    pass "--env-hook with no jq -> 2, no file"
else
    fail "--env-hook with no jq -> 2" "exit: $RC" "stderr: [$ERR]"
fi

# --- F73-F75: the placeholder list ---------------------------------------

# script_keys <script>: the KNOWN_KEYS list of the script, one on each line.
script_keys() {
    sed -n 's/^KNOWN_KEYS="\(.*\)"$/\1/p' "$1" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort
}
# doc_keys <doc>: the first column of the table in the "Placeholders"
# section. The other columns can hold any text.
doc_keys() {
    awk '/^## Placeholders$/{p=1; next} p && /^## /{exit} p' "$1" \
        | sed -nE 's/^\| `\{\{([a-z_]+)\}\}` \|.*/\1/p' | LC_ALL=C sort
}
# same_keys <script> <doc>: true if the two lists are the same.
same_keys() {
    local s d
    s="$(script_keys "$1")"
    d="$(doc_keys "$2")"
    [ -n "$s" ] && [ "$s" = "$d" ]
}
if same_keys "$SCRIPT" "$FAMILIES_DOC"; then
    pass "the script placeholder list equals the docs/families.md table, both ways ($(script_keys "$SCRIPT" | grep -c .) keys)"
else
    fail "the script placeholder list equals the docs/families.md table" \
        "script only: $(comm -23 <(script_keys "$SCRIPT") <(doc_keys "$FAMILIES_DOC") | tr '\n' ' ')" \
        "doc only: $(comm -13 <(script_keys "$SCRIPT") <(doc_keys "$FAMILIES_DOC") | tr '\n' ' ')"
fi
sed '/^| `{{verify}}` |/d' "$FAMILIES_DOC" > "$TMPROOT/families-less.md"
if ! same_keys "$SCRIPT" "$TMPROOT/families-less.md"; then
    pass "control: a docs table with one row removed fails the compare"
else
    fail "control: a docs table with one row removed fails the compare"
fi
sed 's/^KNOWN_KEYS="/KNOWN_KEYS="extra_key /' "$SCRIPT" > "$TMPROOT/script-more"
if ! same_keys "$TMPROOT/script-more" "$FAMILIES_DOC"; then
    pass "control: a script list with one more key fails the compare"
else
    fail "control: a script list with one more key fails the compare"
fi

# template_keys: each {{key}} in the template files, without ${{ ... }}.
unlisted=""
for k in $(find "$TPL" -type f ! -name .DS_Store -exec sed -E 's/\$\{\{[^}]*\}\}//g' {} + \
    | grep -oE '\{\{[a-z_]+\}\}' | tr -d '{}' | LC_ALL=C sort -u); do
    script_keys "$SCRIPT" | grep -qx "$k" || unlisted="$unlisted $k"
done
if [ -z "$unlisted" ]; then
    pass "each {{key}} in the templates is in the script list"
else
    fail "each {{key}} in the templates is in the script list" "not listed:$unlisted"
fi

# --- script rules --------------------------------------------------------

if bash -n "$SCRIPT"; then
    pass "bash -n passes"
else
    fail "bash -n passes"
fi
code="$(grep -vE '^[[:space:]]*#' "$SCRIPT")"
bad=""
printf '%s\n' "$code" | grep -qE '(^|[^a-z_])mapfile|readarray' && bad="$bad mapfile"
printf '%s\n' "$code" | grep -qE 'declare -A|local -A' && bad="$bad declare-A"
printf '%s\n' "$code" | grep -qE 'stat -c' && bad="$bad stat-c"
printf '%s\n' "$code" | grep -qE 'sed -i( |$)' && bad="$bad sed-i"
printf '%s\n' "$code" | grep -qE 'exit 10' && bad="$bad exit-10"
if [ -z "$bad" ]; then
    pass "no mapfile, declare -A, stat -c, sed -i with no suffix, or exit 10"
else
    fail "bash 3.2 and exit code rules" "found:$bad"
fi

harness_report
