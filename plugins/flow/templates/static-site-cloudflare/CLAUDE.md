# CLAUDE.md — {{site_name}}

## Project Overview

{{site_description}}

The site is an Eleventy static site. Eleventy reads the pages in `src/`
and writes the built site to `_site/`. The repo uses the devkit
`static-site-cloudflare` template.

| Command | What it does |
| --- | --- |
| `npm run build` | Builds the site into `_site/`. |
| `npm run serve` | Builds the site and serves it on a local port. |
| `npm run clean` | Removes `_site/`. |
| `npm run lint` | Lints the Markdown files. |

## Deployment

Cloudflare Pages deploys `main` through its Git integration. Cloudflare
builds each push with `npm run build` and serves `_site/`. Cloudflare also
makes a preview for each PR branch.

GitHub CI (`.github/workflows/ci.yml`) builds and lints. It does not
deploy. If the site has Pages Functions in `functions/`, set
`pages_functions: true` in `ci.yml`. CI then compiles the functions.

## Key Conventions

- Put the pages and assets in `src/`.
- Use the Node version in `.nvmrc`.
- Write plan files in `docs/plans/`. Git ignores that folder.

## Never Do

- Do not edit or commit a file in `_site/`.
- Do not commit `.env` or a secret.
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
