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
| `extra_allowed_tools` | string | `""` | Comma-separated tools added to `--allowedTools` in each job. Do not add a git rule (see "No git read commands for Claude"). Do not add a tool that reads PR comments, for example `Bash(gh pr view:*)` or `Bash(gh api:*)` (see "Comment trust"). |
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

### Comment trust

Each review prompt reads the earlier PR comments before it reviews, so
that a settled finding does not come back. On a public repo, any GitHub
user can comment on a PR. A rebuttal from that user could make the reviewer
drop a valid finding (issue #30).

The model does not fetch the comments. In each review job, a
"Fetch PR context" step runs before the Claude step. It writes two files
to `$RUNNER_TEMP/pr-context/`:

- `pr.json` — the PR title, base branch, and head branch.
- `comments.jsonl` — the trusted comments. A jq filter selects them.

The prompt tells the reviewer to read these files. The step gets the PR
number through `env`. It makes one `gh pr view` call and keeps the raw
JSON in a shell variable, not in a file, so the model cannot read the
untrusted comments. If the `gh` call fails, the step fails, and the review
does not run.

The jq filter is in the workflow-level `env:` key `TRUSTED_COMMENTS_JQ`, so
the three jobs use the same filter:

```sh
printf '%s' "$RAW" | jq -c '
  def trusted: .authorAssociation == "OWNER"
    or .authorAssociation == "MEMBER"
    or .authorAssociation == "COLLABORATOR"
    or .author.login == "github-actions";
  (.comments[] | select(trusted)
    | {author: .author.login, association: .authorAssociation, body: .body}),
  {omitted: ([.comments[] | select(trusted | not)] | length)}'
```

The workflow has this jq on one line. The model never reads the text of
the other comments. A trusted comment is one of these:

- A comment with the association `OWNER`, `MEMBER`, or `COLLABORATOR`.
- A comment from `github-actions`. The reviewer's own earlier reviews are
  in this group. The Post review step posts them as `github-actions`, and
  GitHub gives them the association `NONE`. Another workflow that posts
  with `GITHUB_TOKEN` also posts as `github-actions`, so the filter trusts
  its comments too (issue #39).

The step writes one JSON line for each trusted comment. jq escapes the
comment body, so a body cannot add a fake comment header. The last line is
`{"omitted": N}`, the number of other comments. The prompt tells the
reviewer that this number is a count, not evidence.

The step reads only issue comments on the PR. It does not read review
bodies or replies in review threads. So a rebuttal counts only when a
trusted person posts it as a PR comment.

To rebut a finding, post the rebuttal as a normal PR comment. Do not post
it as a reply in a review thread, because the reviewer does not see it.

The review jobs give the model no tool that reads PR comments. Their
`--allowedTools` has no `Bash(gh pr view:*)` and no `Bash(gh pr list:*)`.
`gh pr view <n> --comments` and `gh pr list --json comments` print every
comment, also the untrusted ones.

Do not add a tool that reads PR comments with `extra_allowed_tools`. If you
do, the filter no longer stops the untrusted text. These tools read PR
comments:

- `Bash(gh pr view:*)`, `Bash(gh pr list:*)`, and `Bash(gh issue view:*)`
- `Bash(gh api:*)` and `Bash(gh:*)`
- `WebFetch`, and a GitHub MCP tool that reads issues or PRs

The workflow does not check `extra_allowed_tools` yet (issue #40).

`tests/workflows/test-review-comment-trust.sh` checks the env key, the
fetch step before each Claude step, the file reads and trust text in each
prompt, and the exact `--allowedTools` of each job. The fetch step and the
Claude step must have no `if:` and no `continue-on-error`, so the model
does not run after a failed fetch. The test runs the jq on fixture
comments. It also runs each fetch step with a fake `gh` and checks the
files that the step writes. The step must write nothing in the work
folder, its parent folder, or `HOME`.

### When the caller file changes

`claude-code-action` skips the review when the caller file on the PR branch
is different from the default branch. The `Check workflow match` step in
each review job finds the cause. It compares the head copy with the copy
at the merge base of the head and the default branch:

- **The branch or its base branch changed the file** after the split from
  the default branch. The `Gate` step passes with a warning,
  so the PR that edits the caller is not stuck. `Post review` posts no
  note. A person reviews that PR. The flow scripts still find no verdict
  line for it.
- **Only the default branch changed the file.** The base branch has an old
  copy, for example a branch cut from a release tag. `Post review` posts a
  note, and the `Gate` step fails. To fix it, copy the file from the
  default branch onto the base branch, then run the review again.

The step checks `claude-review.yml` in the same way. With no execution
file and no edited or stale result, the action did not run or stopped
before it started Claude. A failed lookup also gives this result. The
`Gate` step fails and points to the log of the Claude review step.
`Post review` posts a note with the run link when the Claude step ran and
stopped early. When an earlier step failed or the run was cancelled, the
Claude step was skipped or cancelled, and `Post review` posts no note.

Edit a caller only at a milestone boundary (design section 8).

### devkit's own caller

devkit has its own `.github/workflows/claude-code-review.yml`. It calls
`./.github/workflows/claude-review.yml`, the copy in the same commit, not
`@main`. Each devkit PR gets the review. Two kinds of PR skip it:

- A PR that changes the caller file, as in every repo.
- A PR that changes `claude-review.yml`. `claude-code-action` requires a
  reusable workflow in the same repo to match the default branch
  (devkit #27). So devkit cannot review a change to its own review. Test
  such a change in `unibrain1/devkit-sandbox`, and a person reviews it.

In both cases, the Gate passes with the self-referential guard warning
when the branch or its base branch changed the file. So later PRs into a
milestone branch that has the change also pass with the warning: their
copy is newer than the default branch, not older. The secret
`CLAUDE_CODE_OAUTH_TOKEN` is set in devkit. A fork PR gets no review (see
"Fork PRs").

The devkit caller has no `issue_comment` trigger, so devkit has no
`@claude deep-review` comment. devkit is public, and CodeQL flags a
comment run that checks out PR code as a critical alert.

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
| `extra_allowed_tools` | string | `""` | Comma-separated tools added to `--allowedTools`. Do not add a git rule (see "No git read commands for Claude"). |

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

## No git read commands for Claude

The `--allowedTools` value in the `claude_args` of each `claude-code-action`
step in `claude-review.yml` and `claude.yml` has no git rule (issue #29). A
prefix rule such as `Bash(git log:*)` also allows `--output=<file>`, and git
then writes that file. Text injected into a PR could make Claude write
`$GITHUB_ENV`. The runner loads that file into each later step in the job.
In the review jobs, the `Check workflow match` and `Post review` steps
hold `GH_TOKEN`. The `Gate` step holds no token. In
both files, the later steps inside `claude-code-action` v1.0.261 (for
example `Post buffered inline comments`) hold a GitHub token.

A deny rule does not close this path. In the issue #29 probe, the permission
matcher read the command text before the shell removed the quotes. So
`git log --'output'=<file>` passed a `Bash(git * --out*)` rule. The
[probe result](https://github.com/unibrain1/devkit/issues/29#issuecomment-6504295158)
is in issue #29, with Claude Code 2.1.312 and git 2.56.0. The review
prompts use `gh pr diff` and read the files of the Fetch PR context step
(see "Comment trust"). Claude reads full files with `Read`, `Grep`, and
`Glob`.

The `@claude` step in `claude.yml` runs in tag mode. By default, tag mode
in `claude-code-action` v1.0.261 adds its own rules: `Bash(git add:*)`,
`Bash(git commit:*)`, `Bash(git rm:*)`, and a `git push` wrapper. None of
these commands has an `--output` flag. The three review jobs run in agent
mode, and the action adds no rule there.

Do not add a git rule in `extra_allowed_tools`. It brings the write path
back. The workflow does not check this input.
`tests/workflows/test-claude-no-git-prefixes.sh` checks only the
`claude_args` text in the workflow files. It fails on a rule that starts
with `Bash(git` and then has a space, `-`, `:`, `*`, or `)`. It also fails
on `Bash( git` with spaces after the `(`. A rule that allows any command,
`Bash(*` or a bare `Bash` entry, also allows git, so it fails the test too.

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
