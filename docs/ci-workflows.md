# Reusable CI workflows

devkit holds reusable GitHub Actions workflows. A project repo calls one
with its own small caller file.

Each caller job must grant the permissions that the shared jobs need, as in
the examples below. A new repo gives the workflow token read access only,
and a called job cannot get more than its caller. Without the block, the
run fails at startup with "This run likely failed because of a workflow
file issue". `secrets-scan.yml` and `node-site.yml` need only read access,
so their callers need no block. See [design section 6](design.html#ci) for
the shared-CI design and [section 8](design.html#main-match) for the
main-match rule that every caller must follow.

## `claude-review.yml`

A Claude Code review on a pull request, and on demand from a comment.

### Jobs

| Job ID | Runs for |
| --- | --- |
| `pr-to-milestone-review` | Every push to a PR into a milestone branch, or an ad hoc PR straight to the default branch. Also `workflow_dispatch`. |
| `milestone-review` | A milestone PR into the default branch, on open, ready for review, or the `deep-review` label. |
| `comment-deep-review` | A `@claude deep-review` comment from the repo owner (OWNER) or a collaborator (COLLABORATOR). |

### Inputs

| Input | Type | Default | Use |
| --- | --- | --- | --- |
| `pr_number` | string | none, not required | The PR to review, for a manual `workflow_dispatch` run. |
| `review_model` | string | `claude-sonnet-5-5` | Model for `pr-to-milestone-review`. |
| `review_effort` | string | `medium` | Effort for `pr-to-milestone-review`. |
| `milestone_model` | string | `claude-fable-5-1` | Model for `milestone-review` and `comment-deep-review`. |
| `extra_allowed_tools` | string | `""` | Comma-separated tools added to `--allowedTools` in each job. |
| `extra_instructions` | string | `""` | Text added to each prompt, under the heading "Project instructions". |

### Secret

| Secret | Required | Use |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | Yes | The Claude Code OAuth token for the review. |

### Caller example

```yaml
# .github/workflows/claude-code-review.yml
name: Claude Code Review
on:
  pull_request:
    types: [opened, synchronize, ready_for_review, labeled]
  issue_comment:
    types: [created]
  workflow_dispatch:
    inputs:
      pr_number:
        type: number
        required: false
jobs:
  claude-review:
    permissions:
      contents: read
      pull-requests: write
      issues: read
      id-token: write
    uses: unibrain1/devkit/.github/workflows/claude-review.yml@main
    with:
      pr_number: ${{ inputs.pr_number }}
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Name the caller file `.github/workflows/claude-code-review.yml` in every
project. The `flow` plugin scripts expect this name, and the self-
referential guard in `claude-review.yml` reads it from
`github.workflow_ref`.

### Fork PRs

The jobs that resolve a PR number (`pr-to-milestone-review` and
`comment-deep-review`) stop on a fork PR. A `workflow_dispatch` or
`issue_comment` run has the secrets, also for a fork PR. The fork could
then run its own code with them, for example a hook in its
`.claude/settings.json`. A `pull_request` run from a fork gets no secrets,
so the review cannot run there either. A person reviews a fork PR.

These jobs check out the head SHA that they resolve at the start, not the
moving PR ref.

### When the caller file changes

`claude-code-action` skips the review when the caller file on the PR branch
is different from the default branch. The `Gate` step then passes with a
warning, so the PR that edits the caller is not stuck. A person reviews
that PR. The flow scripts still find no verdict line for it. Edit a caller
only at a milestone boundary (design section 8).

### devkit's own caller

devkit has its own `.github/workflows/claude-code-review.yml`. It calls
`./.github/workflows/claude-review.yml`, the copy in the same commit, not
`@main`. So a PR that changes `claude-review.yml` gets a review from its
own changed copy. The caller file stays the same as `main`, so the action
does not skip. A PR that changes the caller file itself skips one time, as
in every repo. The secret `CLAUDE_CODE_OAUTH_TOKEN` is set in devkit. A
fork PR gets no review (see "Fork PRs").

## `claude.yml`

A Claude Code reply to an `@claude` mention, from the repo owner, a member,
or a collaborator.

### Jobs

| Job ID | Runs for |
| --- | --- |
| `claude` | An `@claude` mention in a PR comment, a PR review comment, a PR review, or an issue. Skips a comment that contains `@claude deep-review`; `claude-review.yml` handles that case. |

### Inputs

| Input | Type | Default | Use |
| --- | --- | --- | --- |
| `model` | string | `claude-sonnet-5-5` | Model for the `claude` job. |
| `extra_allowed_tools` | string | `""` | Comma-separated tools added to `--allowedTools`. |

`claude.yml` has no `extra_instructions` input. In `claude-code-action`
v1.0.261, tag mode takes no added text. Put project text for `@claude` in
CLAUDE.md or `.claude/rules/`. The action tells Claude to follow CLAUDE.md.

### Secret

| Secret | Required | Use |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | Yes | The Claude Code OAuth token for the reply. |

### Caller example

```yaml
# .github/workflows/claude.yml
name: Claude Code
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  issues:
    types: [opened, assigned]
  pull_request_review:
    types: [submitted]
jobs:
  claude:
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
      actions: read
    uses: unibrain1/devkit/.github/workflows/claude.yml@main
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

### Fork PRs in `claude.yml`

`claude.yml` does not run on a fork PR. The first step checks the PR and
stops with a notice. A comment run has the secrets, also on a fork PR.
`claude-code-action` restores `.claude/`, `CLAUDE.md`, `.mcp.json`, and a
few other startup files from the base branch before Claude starts. It does
not restore `package.json` or other repo scripts. A tool in
`extra_allowed_tools` that runs repo code would then run the fork's code
with the secrets. An `@claude` mention on an issue is not affected.

## `secrets-scan.yml`

A trufflehog scan of the commits in a pull request or a push. For private
repos. Public repos use GitHub secret scanning and push protection.

| Input | Type | Default | Use |
| --- | --- | --- | --- |
| `extra_args` | string | `--only-verified` | Extra trufflehog arguments. |

Job: `trufflehog`. No secret.

```yaml
# .github/workflows/secrets-scan.yml
name: Secrets scan
on:
  pull_request:
  push:
    branches: [main]
jobs:
  secrets-scan:
    uses: unibrain1/devkit/.github/workflows/secrets-scan.yml@main
```

## `node-site.yml`

Builds and lints a Node static site on Cloudflare Pages. It does not
deploy. Cloudflare Pages deploys `main` through its Git integration.

| Job ID | Does |
| --- | --- |
| `build` | `npm ci`, then `npm run <build_script>`. |
| `lint` | markdownlint on `markdown_globs`. |
| `functions` | Compiles the Pages Functions in `functions/`. Runs only when `pages_functions` is true. |

| Input | Type | Default | Use |
| --- | --- | --- | --- |
| `node_version_file` | string | `.nvmrc` | The file that holds the Node version. |
| `build_script` | string | `build` | The npm script that builds the site. |
| `markdown_globs` | string | `**/*.md`, `#node_modules`, `#_site` | markdownlint-cli2 globs, one on each line. |
| `pages_functions` | boolean | `false` | Also compile the Pages Functions. |

No secret.

```yaml
# .github/workflows/ci.yml
name: CI
on:
  pull_request:
  push:
    branches: [main]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  site:
    uses: unibrain1/devkit/.github/workflows/node-site.yml@main
    with:
      pages_functions: true
```

## `upstream-sync.yml` (devkit only)

Each Monday, compares each upstream plugin pin in
`.claude-plugin/marketplace.json` with upstream HEAD. The logic is in
`.github/scripts/upstream-sync.sh`. If upstream moved, the job opens a PR
that changes the SHA in the marketplace and in `docs/sources.md`, with a
link to each upstream diff. It then starts `self-test.yml` on the branch,
because a PR that `GITHUB_TOKEN` opens starts no `pull_request` workflow.

Read each upstream diff before you merge. The checks do not read it.

The repo setting "Allow GitHub Actions to create and approve pull
requests" must be on. Run it by hand with `gh workflow run upstream-sync.yml`.
