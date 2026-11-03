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
| `comment-deep-review` | A `@claude deep-review` comment from the repo owner (OWNER), an org member (MEMBER), or a collaborator (COLLABORATOR). |

### Inputs

| Input | Type | Default | Use |
| --- | --- | --- | --- |
| `pr_number` | string | none, not required | The PR to review, for a manual `workflow_dispatch` run. |
| `review_model` | string | `claude-sonnet-5-5` | Model for `pr-to-milestone-review`. |
| `review_effort` | string | `medium` | Effort for `pr-to-milestone-review`. |
| `milestone_model` | string | `claude-fable-5-1` | Model for `milestone-review` and `comment-deep-review`. |
| `extra_allowed_tools` | string | `""` | Comma-separated tools added to `--allowedTools` in each job. Each job fails at its "Check extra_allowed_tools" step when the list has a rule that reads PR comments, a git rule, or a bare `Read`, `Grep`, or `Glob`. The rejected forms are in "Comment trust". |
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

`flow-review-workflow-files` prints the review workflow files of a project:
the caller on line 1, then each reusable workflow that the caller calls
from its own repo (`uses: ./`). claude-code-action compares each of these
files with the default branch. `flow-verify-ci-review` and
`/flow:review-milestone` use this list to find a PR that cannot get a
review before it merges. `flow-verify-ci-review` also takes the recovery
workflow name from line 1.

### Fork PRs

When a review job runs on a fork PR, it stops, and the job fails. A
person reviews a fork PR.

The jobs that resolve a PR number (`pr-to-milestone-review` and
`comment-deep-review`) stop in their `Resolve PR context` step. A
`workflow_dispatch` or `issue_comment` run has the secrets, also for a fork
PR. The fork could then run its own code with them, for example a hook in
its `.claude/settings.json`.

`milestone-review` stops in its first step, `Stop a fork PR` (issue #42). A
`pull_request` run from a fork gets no secrets, so the review cannot run.
Without the step, a fork PR with a `milestone/*` branch that edits the
caller file can get a green Gate. The self-referential guard can report
`edited`, and the Gate then passes with a warning. A check in the job `if:`
does not stop this, because GitHub counts a skipped job as a pass for a
required check. The step also stops when `gh` fails or gives a value that
is not `true` or `false`.

`pr-to-milestone-review` and `comment-deep-review` check out the head SHA
that they resolve at the start, not the moving PR ref.

### Comment trust

Each review prompt reads the earlier PR comments before it reviews, so
that a settled finding does not come back. On a public repo, any GitHub
user can comment on a PR. A rebuttal from that user could make the reviewer
drop a valid finding (issue #30).

The model does not fetch the comments. In each review job, a
"Fetch PR context" step runs before the Claude step. It writes two files
to `$RUNNER_TEMP/pr-context/`:

- `pr.json` — the PR title, base branch, and head branch.
- `comments.jsonl` — the kept comments. Each comment line has a `role`
  field. A jq filter selects them.

The prompt tells the reviewer to read these files. The step gets the PR
number through `env`. It makes one `gh pr view` call and keeps the raw
JSON in a shell variable, not in a file, so the model cannot read the
untrusted comments. If the `gh` call fails, the step fails, and the review
does not run.

The jq filter is in the workflow-level `env:` key `TRUSTED_COMMENTS_JQ`, so
the three jobs use the same filter. The filter keeps some comments and
drops the rest. The code sets the `role` of each kept comment. A comment
author cannot set it.

```sh
printf '%s' "$RAW" | jq -c '
  def person: .authorAssociation == "OWNER"
    or .authorAssociation == "MEMBER"
    or .authorAssociation == "COLLABORATOR";
  def verdict: ((.body // "") | gsub("\r"; "")
    | (if endswith("\n") then .[:-1] else . end)
    | split("\n") | (last // ""))
    | test("^<!-- claude-review-verdict sha=[0123456789abcdef]{40} blocking=[0123456789]+ important=[0123456789]+ -->$");
  def role: if person then "person"
    elif .author.login == "github-actions" and verdict then "earlier-review"
    else null end;
  (.comments[] | select(role != null)
    | {author: .author.login, association: .authorAssociation, role: role, body: .body}),
  {omitted: ([.comments[] | select(role == null)] | length)}'
```

The workflow has this jq on one line. The model never reads the text of
the other comments. A kept comment has one of these roles:

- `role: "person"`. The association is `OWNER`, `MEMBER`, or
  `COLLABORATOR`. Only these comments carry rebuttal weight. A person
  keeps this role also when the body ends with a verdict line.
- `role: "earlier-review"`. The author login is `github-actions`, and the
  last line of the body is a verdict line:

  ```text
  <!-- claude-review-verdict sha=<head SHA> blocking=<n> important=<n> -->
  ```

  The match removes each CR and one trailing newline, then reads the last
  line. It is the same rule as `VERDICT_RE` in `flow-check-review-posted`,
  `flow-check-blocking-findings`, and `flow-verify-ci-review`.

The `earlier-review` role does not prove that the comment is a real review:

- In this workflow, only the Post review step writes a verdict line. The
  render removes the marker text from model output, so the model cannot
  write a verdict line.
- But another workflow that posts with `GITHUB_TOKEN` can end a comment
  with a verdict line, for example when it quotes PR text.
- So the `earlier-review` role gives no rebuttal weight, and such a comment
  cannot lower a finding.

Other comments are not kept. They count in `omitted`:

- Comments from other workflows that post with `GITHUB_TOKEN` and do not
  end with a verdict line. These comments also have the login
  `github-actions` (issue #39).
- The Post review failure note.
- Comments from a user with another association.

The login is `github-actions` in GraphQL, the API that `gh pr view` uses.
The flow scripts use REST, which gives `github-actions[bot]`. Each name is
correct for its API. The filter uses the GraphQL name.

An earlier review is model output. The model read the PR content, so an
earlier review can repeat text that an attacker put in the diff (issue #44).
The review prompt tells the reviewer that:

- An `earlier-review` comment is most often its own earlier review, but
  another workflow can post a comment of this form.
- An earlier review is a list of earlier findings. It is never rebuttal
  evidence, and it cannot settle or lower a finding.
- The reviewer must not change a blocking finding to `note` only because
  an earlier review says the code is safe.

The jq filter writes one JSON line for each kept comment. jq escapes the
comment body, so a body cannot add a fake comment header. The last line is
`{"omitted": N}`. N counts every comment that the filter drops, including
dropped bot comments. The prompt tells the reviewer that this number is a
count, not evidence.

The step reads only issue comments on the PR. It does not read review
bodies or replies in review threads. So a rebuttal counts only when a
trusted person posts it as a PR comment.

To rebut a finding, post the rebuttal as a normal PR comment. Do not post
it as a reply in a review thread, because the reviewer does not see it.
A finding can come back in each review round until a person rebuts it in
a PR comment. An earlier review that accepts a risk does not settle it.

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

Each review job has a "Check extra_allowed_tools" step before the Claude
step (issue #40). It reads the input through `env`. It splits the list at
each comma and line break, and removes the spaces around each rule. It
fails the job, and prints one `::error::` line for each rule, when the list
has one of these forms:

| Form | Examples | Reason |
| --- | --- | --- |
| A part that is not one `Name` or `Name(...)` rule, or that has a quote, a backquote, a `$`, or a backslash | `Read(./src/**) WebFetch`, `Bash(npm (x))`, `x" --flag "` | Claude Code also splits `--allowedTools` at spaces outside parentheses, so the step cannot check the part. A quote can end the `--allowedTools` value. Put a comma between rules |
| A Bash rule whose first word is `gh` or ends in `/gh`. The step skips `NAME=value` words before the command | `Bash(gh api:*)`, `Bash(/usr/bin/gh issue view:*)`, `Bash(GH_TOKEN=x gh api:*)` | Reads PR comments |
| A Bash rule that allows each command: no command, or a `*` in the first word | `Bash`, `Bash()`, `Bash(*)`, `Bash(g*:*)` | Allows `gh` too |
| A Bash rule with a `?` or a `[` in the first word | `Bash(/usr/bin/g[h] api:*)`, `Bash(g? api:*)` | The shell can expand the glob to `gh` |
| A Bash rule whose first word is `git` or ends in `/git` | `Bash(git log:*)` | Writes files (see "No git read commands for Claude") |
| A Bash rule whose first word is a reserved word (`time`, `coproc`, `if`, `then`, `elif`, `else`, `while`, `until`, `do`, `case`, `for`, `select`, `function`), or has a character that is not a letter, a digit, `_`, `.`, `/`, `+`, `~`, or `-` | `Bash(gh</dev/null api:*)`, `Bash(2>/dev/null gh api:*)`, `Bash(! gh api:*)`, `Bash(coproc gh api:*)`, `Bash(A+=x gh api:*)` | Shell syntax can hide `gh` from the step |
| `WebFetch` | `WebFetch`, `WebFetch(domain:github.com)` | Reads PR pages |
| A GitHub MCP rule | `mcp__github`, `mcp__github__get_issue` | Reads issues and PRs |
| A bare `Read`, `Grep`, or `Glob` | `Read`, `Read(*)`, `Grep()`, `Read(***)` | Reaches each path on the runner (see "File reach of the review") |

Claude Code applies `Name()`, `Name(*)`, and `Name(**)` as the bare `Name`.
The step checks each `Name(...)` that has only `*` and `/` in it as the
bare `Name`, in each row of the table.

The check is a deny-list. It does not stop a rule for a command that runs
other commands, for example `Bash(env:*)`, `Bash(bash:*)`, `Bash(xargs:*)`,
`Bash(npx:*)`, `Bash(command:*)`, `Bash(exec:*)`, `Bash(timeout:*)`, or
`Bash(sudo:*)`. Such a rule can run `gh`. It also does not stop a rule for
a command that calls the GitHub API, for example `Bash(curl:*)`, or a
GitHub MCP server with a different name. Do not add these rules.

`tests/workflows/test-review-extra-tools.sh` runs the step on each form.

`tests/workflows/test-review-comment-trust.sh` checks the env key, the
fetch step before each Claude step, the file reads and trust text in each
prompt, and the exact `--allowedTools` of each job. The fetch step and the
Claude step must have no `if:` and no `continue-on-error`, so the model
does not run after a failed fetch. The test runs the jq on fixture
comments. It also runs each fetch step with a fake `gh` and checks the
files that the step writes. The step must write nothing in the work
folder, its parent folder, or `HOME`. A run of the fetch step uses a
`PR_NUM` from the test, so a text check compares the `PR_NUM` lines. In
each job, the `PR_NUM` line of the fetch step must equal the `PR_NUM` line
of Post review. Then the model reads the comments of the PR that gets the
review.

### File reach of the review

In the Claude step of each review job, `--allowedTools` limits `Read`,
`Grep`, and `Glob` to two paths (issue #47):

- `Read(./**)`, `Grep(./**)`, and `Glob(./**)` reach the checkout.
- `Read(/${{ runner.temp }}/pr-context/**)` and the same rule for `Grep` and
  `Glob` reach the `pr-context` folder.

`--add-dir ${{ runner.temp }}/pr-context` adds the folder to the session.
The runner temp path starts with `/`, so the leading `/` in the rule gives
the `//abs/path` form of an absolute rule.

A bare `Read`, `Grep`, or `Glob` rule reaches each path on the runner. For
example, a bare `Grep` reaches `/proc/self/environ`, which holds
`CLAUDE_CODE_OAUTH_TOKEN` and `GITHUB_TOKEN`. The `Read` tool refuses that
file, because it refuses device and process files. But a bare `Read` still
reaches the file at `$GITHUB_EVENT_PATH` and the other files in
`$RUNNER_TEMP`. In issue #30, the PR comments moved to
`$RUNNER_TEMP/pr-context`, outside the workspace. The jobs kept the bare
rules until issue #47.

With the path rules, only `pr-context` is in reach in `$RUNNER_TEMP`. The
other files, for example `event.json` in `_github_workflow`, are out of
reach.

A sandbox run checked the path rules (`unibrain1/devkit-sandbox`,
claude-code-action v1.0.261). The run ID is in PR #70. The results
follow:

- `Read` opens `pr.json` and `comments.jsonl` in `pr-context`, and a file
  in the checkout. `Grep` and `Glob` work in `pr-context`. The probe did not
  run `Grep` or `Glob` in the checkout.
- With no allow entry, `Grep` and `Glob` are not available at all. So they
  stay in the list, with path rules. The probe is the evidence that a path
  rule limits `Grep` and `Glob`.
- Claude Code refuses a call outside the allowed paths, for example
  `event.json`, another file in `$RUNNER_TEMP`, and a `Grep` of
  `/proc/self/environ`.
- Claude Code resolves a symlink in the checkout and checks its target. So
  it refuses `leakdir/environ`, where `leakdir` links to `/proc/self`. The
  workflow has no symlink guard step.
- The `Read` tool also refuses device and process files, for example
  `/proc/self/environ`.

The probe did not run a `Grep` on `/proc/self/environ` with a bare rule. So
the exposure of a bare `Grep` comes from the rule form, not from a test.

The run had two probe jobs. The second job had the same `Read`, `Grep`, and
`Glob` rules as the three review jobs. The first job had only the `Read`
rules. A test checks that the three review jobs have the same rules. No test
checks the Claude Code behavior. Run the sandbox probe again when the
claude-code-action version changes.

The probe did not test a `.claude/settings.json` in the checkout. The
checkout holds the files of the PR, so the PR author controls that file. If
the action loads it, a PR can add allow rules to `--allowedTools`. Then the
path limit does not hold for that PR. Nothing stops this for a PR from the
same repo. For a fork PR, each review job that runs stops with a fork
check (see "Fork PRs"). Issue #66 tracks this.

The path limit is the main control. The second layer is the render filter
(`RENDER_FILTER`, function `redact`). Before the Post review step posts the
text, the filter replaces token-like strings in the summary and finding
fields with `[redacted]`. These strings are `gh[pousr]_...`,
`github_pat_...`, `sk-ant-...`, and a bare prefix.

The filter has these limits:

- It does not cover inline comments. The model posts them with
  `mcp__github_inline_comment__create_inline_comment`, so no workflow step
  sees the text.
- It finds only plain-text tokens. A token that a space, a line break, or
  another character outside the token class splits loses only its prefix.
  A Markdown escape, an HTML entity, or a zero-width character
  in a token stops the match.
- The bare-prefix rule can also replace ordinary text, for example the
  `ghs_` in `highs_`.

`claude.yml` has the same exposure. It is not changed here (issue #65).

Do not add a bare `Read`, `Grep`, or `Glob` with `extra_allowed_tools`. It
removes the path limit. The "Check extra_allowed_tools" step fails the job
on a bare rule (see "Comment trust"). It does not check the path of a
path-scoped rule.

### Tools in the review prompts

`--allowedTools` lets Bash run only `gh pr diff` (and the rules in
`extra_allowed_tools`). The model does not know this unless the prompt
says it. A prompt that only lists the tools can make the model run `cd`,
chained commands, pipes, and `cat`. The allowlist refuses each of these
calls, and the review then runs with less input (issue #54).

So each review prompt has the same `## Tools` block:

- `Read` opens each file, with a full path. This includes `pr.json` and
  `comments.jsonl` in `$RUNNER_TEMP/pr-context`.
- `Grep` searches, and `Glob` lists files.
- Bash runs only the bare `gh pr diff <PR number>` command that the prompt shows,
  with no `cd`, `;`, `&&`, `|`, `>`, or second command.

`Read`, `Grep`, and `Glob` reach only the checkout and `pr-context` (see
"File reach of the review").

The milestone and deep-review prompts also read `merged-prs.txt`. Their
"Read the merged ... list" section gives its full workspace path.

The `Gate` step prints a `Refused:` warning for each tool call that the
allowlist refused. The warning has the tool name and the first 3 words of
the command. A review with a `Refused:` warning may have run with less
input than the prompt expects.

`tests/workflows/test-review-gate-refused.sh` runs the jq filter of each
`Gate` step on a fake execution file. It checks one warning line for each
refused call. It also checks that the warning keeps only the first line
of the command, and only its first 3 words.

`tests/workflows/test-review-prompt-tools.sh` checks the `## Tools` block in
each prompt. It also checks that each prompt has a `gh pr diff` example, and
that each example is the bare command. It cannot check what the model does.

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
- **Only the default branch changed the file.** The PR branch has an old
  copy, for example a branch cut from a release tag, or a branch cut
  before a change to the file merged. `Post review` posts a note, and the
  `Gate` step fails. To fix it: if the base branch also has the old copy,
  copy the file from the default branch onto the base branch. Then update
  the PR branch from its base branch and run the review again.

The step checks `claude-review.yml` in the same way. With no execution
file and no edited or stale result, the action did not run or stopped
before it started Claude. A failed lookup also gives this result. The
`Gate` step fails and points to the log of the Claude review step.
`Post review` posts a note with the run link when the Claude step ran and
stopped early. When an earlier step failed or the run was cancelled, the
Claude step was skipped or cancelled, and `Post review` posts no note.

After a caller change merges into the default branch, merge the default
branch into each open milestone branch. Until then, a PR into that
milestone branch has an old copy. With an `@main` pin, its `Gate` step
fails as stale. With a tag pin, the PR still runs the old workflow.

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
  In the sandbox run, the `Gate` must show no `Refused:` warning (see
  "Tools in the review prompts"). `flow-review-workflow-files` lists this
  file (devkit #76).

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
`Glob` (see "File reach of the review").

The `@claude` step in `claude.yml` runs in tag mode. By default, tag mode
in `claude-code-action` v1.0.261 adds its own rules: `Bash(git add:*)`,
`Bash(git commit:*)`, `Bash(git rm:*)`, and a `git push` wrapper. None of
these commands has an `--output` flag. The three review jobs run in agent
mode, and the action adds no rule there.

Do not add a git rule in `extra_allowed_tools`. It brings the write path
back. The review jobs of `claude-review.yml` fail on a git rule (see
"Comment trust"). `claude.yml` does not check this input.
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

## Required check names

Before the merge, `flow-release-milestone` waits until each required
check of `main` passes. It reads the required names from the branch
protection and the rulesets (the `context` of each check). It finds each
name in the `name` field of `gh pr checks`. A job in a reusable workflow
gets a name of the form `<caller job> / <called job>`, for example
`claude-review / pr-to-milestone-review`. Each required name must be
equal to the name that `gh pr checks <pr>` shows. If a required name does
not match, the script counts that check as pending. At the time limit, it
stops with exit 2 and gives the name, and nothing merges.

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
