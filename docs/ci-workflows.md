# Reusable CI workflows

devkit holds reusable GitHub Actions workflows. A project repo calls one
with its own small caller file. See [design section 6](design.html#ci) for
the shared-CI design and [section 8](design.html#main-match) for the
main-match rule that every caller must follow.

## `claude-review.yml`

A Claude Code review on a pull request, and on demand from a comment.

### Jobs

| Job ID | Runs for |
| --- | --- |
| `pr-to-milestone-review` | Every push to a PR into a milestone branch, or an ad hoc PR straight to the default branch. Also `workflow_dispatch`. |
| `milestone-review` | A milestone PR into the default branch, on open, ready for review, or the `deep-review` label. |
| `comment-deep-review` | A `@claude deep-review` comment from the PR owner or a collaborator. |

### Inputs

| Input | Type | Default | Use |
| --- | --- | --- | --- |
| `pr_number` | number | none, not required | The PR to review, for a manual `workflow_dispatch` run. |
| `review_model` | string | `claude-sonnet-5` | Model for `pr-to-milestone-review`. |
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
| `model` | string | `claude-sonnet-5` | Model for the `claude` job. |
| `extra_allowed_tools` | string | `""` | Comma-separated tools added to `--allowedTools`. |
| `extra_instructions` | string | `""` | Text added to the prompt, under the heading "Project instructions". |

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
    uses: unibrain1/devkit/.github/workflows/claude.yml@main
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Other workflows: see below.
