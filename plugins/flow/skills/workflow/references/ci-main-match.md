# CI and the main-match rule

## The main-match rule

A Claude workflow on a branch must match the copy on `main`. Otherwise it does not run, or it skips the review. The cause is GitHub and `claude-code-action`.

- GitHub runs only the workflow file on the default branch for `comment`, `issue`, `schedule`, and `pull_request_target` events. A branch copy never runs.
- A `workflow_dispatch` workflow must exist on the default branch.
- `claude-code-action` compares the workflow file on the PR head with the copy on the default branch. If they differ, the action skips the review.
- In one project, a PR that edited the review workflow was never reviewed by Claude.

## Workflow parity

A change to `.github/workflows/` must end up the same on the working branch and on `main`. A workflow that differs between them makes branch CI results a poor predictor of `main`.

- Before you commit a workflow change, run `git diff origin/main <branch> -- .github/`.
- If a new step needs files that exist only on the milestone branch, ask the user how to sync it. The step fails on `main`.

## Edit a caller only at a milestone boundary

A caller file is the file in a project that calls a shared CI workflow.

- Edit a caller only between milestones. That is after `/flow:release-milestone` and before `/flow:start-milestone`.
- A caller edit in the middle of a milestone makes each open branch keep the old file. The review then skips each open PR.
- In a repo with no milestone branches, edit a caller only when no other PR is open. Or update the open branches from `main` after the merge.
- A hotfix PR is safe. A hotfix branch starts from `main`, so its callers match `main`.

## Caller interface

- Give each new input a default value. Callers then need no edit.
- Keep job names stable. A rename breaks required checks in every repo at once.
- Pass each secret by name. Do not rely on secret inheritance across orgs.
