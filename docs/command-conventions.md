# Command conventions

Rules for the command files in `plugins/flow/commands/`. Each command must
work in every repo that uses `flow`. A project fact comes from
`.claude/project.md`, never from the command text.

## Frontmatter

- Keep `description`, `model`, `argument-hint`, and `allowed-tools` from the
  source. In `allowed-tools`, use the `flow-*` script names.
- Do not change `model:`. The hand-off rule depends on it.

## First step: project facts

Each command starts with this step, before any other step:

```markdown
## Step 0: Project facts

1. Run `flow-project-check`. If it fails, show its output. Tell the user to
   fix `.claude/project.md` or run `/flow:setup`. Stop.
2. Read each fact that this command needs with `flow-project-fact <key>`.
```

`/flow:setup` is the only exception, because it creates the file.

## Version check: Step 0b

A command that takes a version and changes GitHub or git checks the
version before it changes anything. `/flow:plan-milestone` and
`/flow:start-milestone` do this in Step 0b with
`flow-check-version-newer`. A bad form or a version that is not newer stops
the command. `tests/commands/test-version-check-at-start.sh` checks that
Step 0b comes before each write command.

## Project facts

- Read a fact with `flow-project-fact <key>`. The keys are in
  [project-md.md](project-md.md).
- Never write a project command, path, or name in a command. Examples of what
  is not allowed: `composer`, `npm test`, `docker compose`, `docs/plans`,
  `CLEANUP_LEDGER.md`, `elan-registry/registry`, `usersc/`, `UserSpice`.
- Get the repo with `flow-repo` and the visibility with
  `flow-repo --visibility`.
- During an issue, run `test_quick` if the key exists, else `test`. Before
  a PR opens, run `test`.

## Scripts

- Call a flow script by name, for example `flow-check-plan-state`. The
  plugin's `bin/` is on the command path. Never write `scripts/<name>.sh`.
- A Registry script that is not in `flow/bin/` becomes a key:

  | Registry script | Use instead |
  | --- | --- |
  | `check-baseline-hygiene.sh` | `issue_checks` |
  | `check-known-broken-tests.sh`, `check-deploy-sheet-fresh.sh` | `milestone_checks`, `release_checks` |
  | `run-verification-suite.sh` | `verify` |
  | `refresh-local-db.sh`, `list-fix-scripts.sh` | `milestone_setup` |
  | `render-deploy-sheet.sh`, `build.js`, `server-hooks/` | the `deploy` key, in words only |
  | `sprint-status.sh` | nothing (dropped) |

- Run a check key as a shell command. A non-zero exit stops the command.
- Exit 10 from a flow script means "step skipped, optional key absent". Add
  the step to the skipped list and go on.

## Agents and skills

- Name a flow agent with its plugin prefix: `flow:code-reviewer`,
  `flow:senior-architect`, and so on. Built-in agents keep their names, for
  example `general-purpose` and `Explore`.
- The method is in the `flow:workflow` skill. Cite it as
  "the `flow:workflow` skill, `<file>`, `<heading>`". Do not cite
  `ISSUE_WORKFLOW.md` or a CLAUDE.md section of a project.
- Coding standards come from the `standards` key and the project's
  `.claude/rules/`. Do not cite `CODING_STANDARDS.md`.
- The hotfix procedure is the `flow:hotfix` skill.
- Other commands: write `/flow:<name>`. `/commit` stays `/commit`.

## Last step: report

Each command ends with a report that has this list:

```markdown
Skipped steps:
- <step>: <reason>, for example "release_checks: no key in .claude/project.md"
```

Write "Skipped steps: none" when no step skipped. Then state the next
command and the hand-off rule from the `flow:workflow` skill, "Hand-offs
between commands".

## Style

The commands are instructions for an agent. Use ASD-STE100 Strict: active
voice, one instruction for each sentence, short sentences, no semicolons,
and one word for one thing. Keep code identifiers, commands, and key names
as they are.
