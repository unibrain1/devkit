# `.claude/project.md`

Each repo that uses the `flow` plugin has a file `.claude/project.md`. It
tells the shared commands and scripts the facts that change from project to
project: how to test, how to lint, and where the project keeps its plans and
release notes.

Claude Code does not load this file in a normal session. Each shared command
reads it in its first step. Do not import it into CLAUDE.md with `@`.

## Format

One fact on each line, in this form:

```markdown
- key: `value`
```

- The value is the text between the first pair of backticks.
- A line with no backticks gives the text after the colon. Example:
  `- deploy: see docs/DEPLOY.md`.
- If a key occurs two times, the first line wins.
- Other lines (headings, comments) have no effect.

Scripts read a value with `flow-project-fact <key>`.

## Keys

| Key | Need | Use |
| --- | --- | --- |
| `test` | Necessary | The command that runs the tests. |
| `lint` | Necessary | The command that runs the linter or static analysis. |
| `format` | Optional | The command that formats the code. |
| `verify` | Optional | The full verification command before a review or release. |
| `deploy` | Optional | The deploy guide or command. |
| `standards` | Optional | Coding standards files that the agents read. Separate paths with a space. |
| `plans` | Optional | The folder for issue plan files. It must be git-ignored. `release-milestone` needs it. |
| `release_notes` | Optional | The path pattern for release notes. `{version}` is the milestone version. `release-milestone` needs it. |
| `ledger` | Optional | The list of deferred cleanup items. |
| `private_paths` | Optional | Paths that must never go into a commit. Separate paths with a space. |
| `milestone_setup` | Optional | A command that `start-milestone` runs after it makes the branch. |
| `issue_checks` | Optional | A command that `finish-issue` runs before it opens the PR. |
| `milestone_checks` | Optional | A command that `finish-milestone` runs before the milestone PR. |
| `release_checks` | Optional | A command that `release-milestone` runs before the merge. |
| `vault` | Optional, v1.1 | The hub note path in the Baalda vault. |

## Missing keys

- If the file is missing, a shared command stops and tells you to create it.
- If an optional key is missing, the command skips that step with no error.
  The scripts in `flow/bin/` follow one rule:

  | The key gates | Absent key |
  | --- | --- |
  | The whole script | The script prints `Step skipped.` and exits 10. No script uses 10 for another meaning. |
  | One check in the script | The script prints `<check> skipped.` and goes on. Example: `private_paths` in `flow-commit-push-pr`. |
  | Work that cannot run without it | The script stops with exit 2 and names the key. Example: `release_notes` and `plans` in `flow-release-milestone`. |

- A check command (`*_checks`, `milestone_setup`) that exits non-zero stops
  the shared command.

## No silent skips

A typo in a key name must not turn off a check.

- Each shared command runs `flow-project-check` in its first step. An
  unknown key stops the command, and the error names the nearest known key.
  A missing `test` or `lint` key also stops the command.
- At the end, each shared command prints a "Skipped steps" list with the
  reason for each step.

To add a key, add it to this table and to `KNOWN_KEYS` in
`plugins/flow/bin/flow-project-check`.

## Example (Registry)

```markdown
# Project facts for devkit commands

- test: `docker compose exec -u www-data app composer test:full`
- lint: `composer phpstan`
- format: `composer cs:fix`
- verify: `scripts/run-verification-suite.sh`
- deploy: see `docs/development/DEPLOYMENT.md`
- standards: `docs/development/CODING_STANDARDS.md`
- plans: `docs/plans`
- release_notes: `docs/releases/RELEASE_NOTES_{version}.md`
- ledger: `docs/development/CLEANUP_LEDGER.md`
- private_paths: `docs/plans _noupload`
- issue_checks: `scripts/check-baseline-hygiene.sh`
- milestone_checks: `scripts/check-deploy-sheet-fresh.sh`
- release_checks: `scripts/check-deploy-sheet-fresh.sh`
```
