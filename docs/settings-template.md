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

- `flow-commit-push-pr`, `flow-release-milestone`
- `flow-claude-block` (writes CLAUDE.md)
- `flow-verify-ci-review` (can start the review workflow)
- `flow-labels --create`

`tests/templates/test-settings-template.sh` fails if one of them goes into
the allowlist, or if the allowlist names a script that does not exist.

## After you copy it

1. Add the project's own test and lint commands to `permissions.allow`, for
   example `Bash(composer test:quick *)`. They are the `test`, `test_quick`,
   and `lint` keys in `.claude/project.md`.
2. Keep the project's own `hooks` and other keys. Merge, do not replace.
3. For Registry, change `"ref": "main"` to the devkit tag.
4. Install the plugins at project scope:
   `claude plugin install flow@devkit --scope project`. If `/plugin` shows
   `flow` at user scope, uninstall it there. A user-scope install loads
   `flow` in every repo, and a `ref` change in another project can leave it
   with no cache (design section 5).
