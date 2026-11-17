# CLAUDE.md — {{app_name}}

## Project Overview

{{app_description}}

The repo builds a container image and pushes it to GHCR (`ghcr.io`). The
repo uses the devkit `container-ghcr` template.

| Command | What it does |
| --- | --- |
| `{{test}}` | Runs all the tests. |
| `{{test_quick}}` | Runs the fast tests. The pre-commit hook runs it at each commit. |
| `{{lint}}` | Runs the linter. |

## Deployment

`.github/workflows/container-image.yml` lints the Dockerfile with
hadolint and builds the image. The tags come from the event:

| Event | Image tags |
| --- | --- |
| A PR | None. CI builds the image and does not push it. |
| A push to `main` | `edge` and `sha-<7 hex>`. |
| A tag `vX.Y.Z` | `X.Y.Z`, `X.Y`, and `latest`. |

The host pulls `latest` or a version tag. It never pulls `edge`, a `sha-`
tag, or `main`. Thus only a release changes what the host runs.

A hotfix also gets a patch tag, for example `v1.2.4`, so that `latest`
moves to the fix.

GitHub CI (`.github/workflows/ci.yml`) runs the lint and the tests of the
app.

## Key Conventions

- Keep secrets in `.env` files. Git ignores them, and `.dockerignore`
  keeps them out of the image. Commit only `.env.example`.
- Write plan files in `docs/plans/`. Git ignores that folder.
- Run `pre-commit install` one time in each clone. The hadolint hook needs
  Docker.

## Never Do

- Do not read, change, or commit an `.env` file.
- Do not put a secret in the image or in a build argument.
- Do not point the host at `edge`, a `sha-` tag, or `main`.
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
