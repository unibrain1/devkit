---
description: Run a security review of recent code changes (OWASP, CSRF, SQL injection, XSS)
model: haiku
---

# Security Review

This is the flow command `/flow:security-review`. It does not replace Claude
Code's built-in `/security-review`.

Keep output brief — terse status lines, no preamble, no restating of steps.

## Step 0: Project facts

1. Run `flow-project-check`. If it fails, show its output. Tell the user to
   fix `.claude/project.md` or run `/flow:setup`. Stop.
2. Read each fact that this command needs with `flow-project-fact <key>`:
   `standards`. Exit 1 means the key is absent. Go on.

Perform a comprehensive security audit of recent code changes in this project.

For plan-driven work, `/flow:execute-plan` already launches `flow:security-reviewer`
against the full diff whenever the plan's security section is non-empty or a
changed file touches forms, SQL, or auth. This command
is largely superseded for that path. Use it directly for ad-hoc work with no
plan file, or to re-run a security pass in isolation without repeating the
rest of the review round of `/flow:execute-plan`.

## Steps

1. **Identify changed files**: Review the whole branch, not only the
   uncommitted part. The scope is every commit since the branch left its
   base, plus staged, unstaged and untracked changes. Use the PR's base
   branch when a PR exists. Otherwise resolve the base with
   `flow-resolve-base-branch`. Issue branches start from
   `milestone/vX.Y.Z`, so a diff against `main` adds the whole milestone.

   ```bash
   # An empty --head lists every open PR, so skip the lookup on a detached HEAD.
   BRANCH=$(git branch --show-current)
   BASE=
   [ -n "$BRANCH" ] && BASE=$(gh pr list --head "$BRANCH" --state open \
     --json baseRefName --jq '.[0].baseRefName // empty' \
     --repo "$(flow-repo)" 2>/dev/null)
   if [ -z "$BASE" ]; then
     BASE=$(flow-resolve-base-branch) || { echo "could not resolve a base branch (detached HEAD?)" >&2; exit 1; }
     BASE=${BASE#origin/}
   fi
   MERGE_BASE=$(git merge-base HEAD "origin/$BASE" 2>/dev/null || git merge-base HEAD "$BASE") \
     || { echo "no merge base with $BASE" >&2; exit 1; }
   echo "BASE=$BASE MERGE_BASE=$MERGE_BASE"
   # Committed, staged and unstaged changes since the merge base
   git diff --name-only "$MERGE_BASE"
   # Untracked files
   git ls-files --others --exclude-standard
   ```

   Exit 1 means that no base or merge base was found, for example on a
   detached HEAD. Stop and report the message. Do not fall back to
   `origin/main`. Check out the branch, then run `/flow:security-review` again.

2. **Filter to relevant files**: Focus on source code files. Skip
   documentation, tests, and static assets unless they contain security-relevant
   code.

3. **Launch the security-reviewer agent** via the Agent tool with
   `subagent_type: "flow:security-reviewer"`. Provide it with:
   - The list of changed files and untracked files from step 1
   - The full diff: `git diff <MERGE_BASE>`, with the SHA that step 1
     printed
   - Instructions to read and review each changed file completely, and each
     untracked file, which the diff does not show
   - Instructions to read the coding standards in these files: the value of
     the `standards` key (if the key exists), and the files in the project's
     `.claude/rules/` folder (if it exists)

4. **Report results**: Present the security-reviewer agent's findings to the
   user. If critical or high severity issues are found, recommend fixing them
   before proceeding.

5. **Next step**: Tell the user in plain text. Fix Critical and High
   findings first. Then find the state of the branch. Run:

   ```bash
   git status --porcelain
   gh pr list --head "$(git branch --show-current)" --state open \
     --json number --jq '.[0].number // empty' --repo "$(flow-repo)"
   ```

   Pick the next command from the state:

   | State | Next command |
   | --- | --- |
   | `git status --porcelain` prints a line | `/commit` |
   | No uncommitted changes and no open PR | `/flow:review-pr` |
   | An open PR exists | `/flow:address-pr-comments` |

   Use the first row that matches. The order of the workflow is `/commit`,
   then `/flow:review-pr`, then `/flow:commit-push-pr`. Recommend `/clear` and
   then that command. The next command does not need this review's context.
   This command does not start it. The hand-off rule is in the `flow:workflow`
   skill, `SKILL.md`, `Hand-offs between commands`.

## When to Use

- Before creating a commit or pull request
- After implementing features that handle user input, authentication,
  database queries, or file operations
- As a mandatory check when the project's rules require it

The security-reviewer agent defines its own comprehensive checklist
(OWASP top 10, project-specific patterns). See the `flow:security-reviewer`
agent for the full scope.

## Last step: Report

End with this list:

```text
Skipped steps:
- <step>: <reason>, for example "standards: no key in .claude/project.md"
```

Write "Skipped steps: none" when no step skipped.
