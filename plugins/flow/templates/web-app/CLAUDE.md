# CLAUDE.md — {{app_name}}

## Project Overview

{{app_description}}

The app is a web app with a database. The repo uses the devkit `web-app`
template.

| Command | What it does |
| --- | --- |
| `{{test}}` | Runs all the tests. |
| `{{test_quick}}` | Runs the fast tests. The pre-commit hook runs it at each commit. |
| `{{typecheck}}` | Runs the type check. The pre-commit hook runs it at each commit. |
| `{{lint}}` | Runs the linter. |
| `{{verify}}` | Runs the full check before a release. |

## Deployment

{{deployment}}

GitHub CI (`.github/workflows/ci.yml`) runs the lint and the tests. It does
not deploy.

## Versioning

The milestone branch name holds the version: `milestone/vX.Y.Z`.
`/flow:start-milestone` runs the `milestone_setup` key, which writes the
version into the app. `/flow:release-milestone` runs the `release_checks`
key, which stops the release when the app version and the branch do not
agree.

## Key Conventions

- Keep secrets in `.env` files, or in `.dev.vars` for Wrangler. Git
  ignores them. Commit only the
  example files, such as `.env.example`.
- Write plan files in `docs/plans/`. Git ignores that folder.
- Run `pre-commit install` one time in each clone.

## Never Do

- Do not read, change, or commit an `.env` or `.dev.vars` file.
- Do not change the production database by hand.
- Do not push to `main` directly. Use a PR.

<!-- flow:begin rev 1 -->
## Developer workflow (flow)

Branches: `main` ← `milestone/vX.Y.Z` ← `issue/NNN-slug`. One PR for each
issue, to the milestone branch. A hotfix branches from `main` (the
`flow:hotfix` skill).

```text
/flow:plan-milestone → /flow:start-milestone
  per issue: /flow:start-issue → /flow:execute-plan → /commit → /flow:review-pr
             → /flow:commit-push-pr → /flow:address-pr-comments → /flow:finish-issue
/flow:finish-milestone → /flow:review-milestone → /flow:release-milestone
```

Hand-offs: start the next command through the Skill tool only when both
commands declare the same `model:`. Otherwise, tell the user to type it.
At an issue or milestone boundary, recommend `/clear` first.

Project facts for these commands are in `.claude/project.md`. The full
method is in the `flow:workflow` skill.
<!-- flow:end -->
