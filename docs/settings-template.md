# `templates/settings.json`

A plugin cannot ship a permission allowlist. So each project copies
`templates/settings.json` to `.claude/settings.json` one time, when it
migrates. After that, the project owns its copy (design section 5).

## What the template holds

| Key | Value | Why |
| --- | --- | --- |
| `extraKnownMarketplaces.devkit` | `unibrain1/devkit`, `ref: main`, auto-update on | Private repos follow `main`. Registry changes `ref` to its tag, for example `v0.1.0`. |
| `enabledPlugins` | `flow@devkit`, `asd-ste100@devkit` | The shared workflow and the writing skill. |
| `attribution` | empty commit and PR text, no session URL | Commits and PRs get no tool attribution lines. |
| `permissions.allow` | flow scripts that only read, and `gh` commands that only read | Commands call these often. Each one changes nothing. |
| `permissions.deny` | `Skill(commit-commands:commit-push-pr)` and its `:*` form | `/flow:commit-push-pr` replaces it. The deny stops Claude from picking the other one. From Registry. |

## Not in the allowlist

These scripts push, merge, write files, or start workflows. Claude asks
before each run:

- `flow-commit-push-pr`, `flow-release-milestone`, `flow-release-hotfix`
- `flow-claude-block` (writes CLAUDE.md)
- `flow-verify-ci-review` (can start the review workflow)
- `flow-labels --create`
- `flow-baseline --apply` (writes the baseline files). The template allows
  `flow-baseline --status`, which only reads.

`tests/templates/test-settings-template.sh` fails if one of them goes into
the allowlist, or if the allowlist names a script that does not exist.

The template allows `flow-plugins --status`, not all of `flow-plugins`.
`--status` is its only mode today. `/flow:setup` and `/flow:new-project`
start it with `--status`. The narrow rule makes Claude ask before a mode
that a later version adds.

## After you copy it

1. Add the project's own test and lint commands to `permissions.allow`, for
   example `Bash(composer test:quick *)`. They are the `test`, `test_quick`,
   and `lint` keys in `.claude/project.md`.
2. Keep the project's own `hooks` and other keys. Merge, do not replace.
3. For Registry, change `"ref": "main"` to the devkit tag.
4. Install both plugins in `enabledPlugins` at project scope. An enabled
   plugin that is not installed does not load, and a stale plugin loads an
   old version. `/flow:setup` checks this. It runs `flow-plugins --status`,
   shows the fix command for each missing or stale plugin, and runs it
   after your approval. The SessionStart hook also reports a missing or
   stale plugin. If you cannot run `/flow:setup`, install the plugins with
   these commands:

   ```sh
   claude plugin install flow@devkit --scope project
   claude plugin install asd-ste100@devkit --scope project
   ```

   The update command keeps the scope of the install that
   `flow-plugins` finds: `--scope project`, `--scope local`, or
   `--scope user`. If only the running copy is old and the install is
   current, the fix is `restart the session`.

   Claude Code keeps one checkout for each marketplace. The last project
   that opens sets its `ref`. If this repo's `ref` is not the `ref` of that
   checkout (for example, Registry pins a tag and another repo uses
   `main`), `flow-plugins` prints `unknown` for the plugin and the reason
   on stderr. It cannot know the expected version then.

   If `/plugin` shows
   `flow` at user scope, uninstall it there. A user-scope install loads
   `flow` in every repo, and a `ref` change in another project can leave it
   with no cache (design section 5). For a stale `flow` at user scope,
   `/flow:setup` does not show the update command. It shows
   `claude plugin uninstall flow@devkit --scope user` and
   `claude plugin install flow@devkit --scope project` in its place.

5. Check `.claude/settings.json` after the installs. `/flow:setup` runs
   this compare after its installs. The install writes the file again in
   its own key order, also when `enabledPlugins` already has the plugin.
   If only the key order changed, discard the change. First run
   `git cat-file -e HEAD:.claude/settings.json`. If it does not exit 0,
   `HEAD` has no copy of the file, and there is nothing to compare.
   Then run this compare:

   ```sh
   if tmp="$(mktemp -d)" &&
     git show HEAD:.claude/settings.json > "$tmp/head.raw" &&
     jq -S . "$tmp/head.raw" > "$tmp/head.json" &&
     jq -S . .claude/settings.json > "$tmp/work.json"; then
     if cmp -s "$tmp/head.json" "$tmp/work.json"; then
       git checkout -- .claude/settings.json
     else
       diff "$tmp/head.json" "$tmp/work.json"
     fi
   else
     echo "compare failed: .claude/settings.json not changed" >&2
   fi
   rm -rf "$tmp"
   ```

   Each `jq -S` writes the content with sorted keys to a temp file. The
   `git checkout` runs only when both `jq` commands exit 0 and the two
   files are equal. Do not use `diff <(...)` for this compare. A process
   substitution hides a failed `jq`. Then both sides are empty, `diff`
   exits 0, and `git checkout` discards a real change.
