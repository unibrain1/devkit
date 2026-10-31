# `.claude/project.md`

Each repo that uses the `flow` plugin has a file `.claude/project.md`. It
tells the shared commands and scripts the facts that change from project to
project: how to test, how to lint, and where the project keeps its plans and
release notes.

Claude Code does not load this file in a normal session. Each shared command
reads it in its first step. Do not import it into CLAUDE.md with `@`.

To create it, run `/flow:setup`. The command also adds the flow block to
CLAUDE.md. A SessionStart hook tells you when the file or the block is
missing or old.

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

If `.gitignore` ignores `.claude/*`, add `!.claude/project.md` next to the
other exceptions. Else git does not see the file.

## Keys

| Key | Need | Value | If absent | Use |
| --- | --- | --- | --- | --- |
| `test` | Necessary | A command | Stop | The command that runs the tests. |
| `test_quick` | Optional | A command | Use `test` | A faster test set for work in progress. Commands use it during an issue. |
| `lint` | Necessary | A command | Stop | The command that runs the linter or static analysis. |
| `format` | Optional | A command | No effect. No command reads it yet | The command that formats the code. |
| `verify` | Optional | A command | Skip the step. `review-pr` runs `test` and `lint` instead | The full verification command before a review or release. |
| `deploy` | Optional | Free text | The command asks the user | A pointer to the deploy document or command. A person or an agent reads it. No script reads it. |
| `standards` | Optional | A list of paths, separated by spaces | Skip the step | Coding standards files that the agents read. |
| `plans` | Optional | A path | `start-issue`, `execute-plan`, `finish-milestone`, `review-milestone`, and `release-milestone` stop. Other commands skip the plan step | The folder for plan files. It must be git-ignored. It holds `issues/` (issue plans) and `releases/` (release notes copies, retrospectives, review markers). |
| `release_notes` | Optional | A path pattern with `{version}` | `release-milestone` stops. Other commands skip the step | The path pattern for release notes. `{version}` is the milestone version. |
| `release` | Optional | One of `publish` or `draft` | Publish | How `release-milestone` creates the GitHub release. `publish` makes a published release and marks it Latest. `draft` makes a draft release, and the deploy procedure publishes it. Any other value stops the script with exit 2 before the merge. |
| `ledger` | Optional | A path | Skip the step | The list of deferred cleanup items. |
| `private_paths` | Optional | A list of paths, separated by spaces | Skip the check | Paths that must never go into a commit. |
| `milestone_setup` | Optional | A command | Skip the step | A command that `start-milestone` runs after it makes the branch. |
| `issue_checks` | Optional | A command | Skip the step | A command that `execute-plan` runs after the code changes, and `review-pr` and `finish-issue` run before the merge. It gets the changed file names on stdin, one name on each line. |
| `milestone_checks` | Optional | A command | Skip the step | A command that `finish-milestone` runs before the milestone PR. |
| `release_checks` | Optional | A command | Skip the step | A command that `release-milestone` runs before the merge. |
| `vault` | Optional, v1.1 | A path | No effect. No command reads it yet | The hub note path in the Baalda vault. |

## Missing keys

- If the file is missing, a shared command stops and tells you to create it.
- If an optional key is missing, the command does what the **If absent** column
  says. Most keys skip the step with no error.
  The scripts in `flow/bin/` follow one rule:

  | The key gates | Absent key |
  | --- | --- |
  | The whole script | The script prints `Step skipped.` and exits 10. No script uses 10 for another meaning. |
  | One check in the script | The script prints `<check> skipped.` and goes on. Example: `private_paths` in `flow-commit-push-pr`. |
  | Work that cannot run without it | The script stops with exit 2 and names the key. Example: `release_notes` and `plans` in `flow-release-milestone`. |

- The `release` key is different. If it is absent, `flow-release-milestone`
  does not skip a step. It sets a behavior: it publishes the release.
  A value that is not `publish` or `draft` exits 2, before the merge.
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
- test_quick: `composer test:quick`
- lint: `composer check`
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
