# Interrupts

## Interrupts and the hotfix track

Only one thing interrupts a milestone: production is broken, data is at risk, or a security exposure exists. That work is a hotfix.

- A hotfix branches from `main`.
- It ships as a patch release, outside the milestone.
- It does not join the milestone or change its scope.
- For the step-by-step procedure, load the `hotfix` skill (`flow:hotfix`).

Everything else queues. Acknowledge the request. Capture it with `/flow:new-issue`. Let it wait for the next planning session. Do not reorder the release.

### Entry points

Choose the entry point by the state of the current work.

| State | Run | Then |
| --- | --- | --- |
| No issue in progress | `/flow:new-issue` with `signal:defect`. Labels: `bug`, `triage`. | Its last step names `/flow:start-issue <N> --hotfix`. |
| An issue in progress | `/flow:found`. It creates the hotfix issue with labels `bug`, `triage`, `signal:defect`. It writes `Paused for hotfix: #<N>` in the hotfix issue body. | Save the paused work. Then run `/clear`. Then run `/flow:start-issue <N> --hotfix`. |

Do not use `/flow:found` when no issue is in progress. It is for finds made during an issue.

### Save the paused work

- Commit the work on the issue branch. Prefer this. `/flow:start-issue` stops while uncommitted changes exist.
- Or stash the work. Before the paused issue resumes, check out its branch and run `git stash pop` on that branch.

### Hotfix rules

- `/flow:start-issue <N> --hotfix` branches from `origin/main`.
- The plan gate applies.
- The plan records `none (hotfix)` as the milestone and `main` as the PR base.
- The command skips the readiness check.
- The command writes the acceptance criteria in the plan. It posts them to the issue on approval.
- A hotfix takes no cleanup ledger edits. `/flow:start-issue`, `/flow:execute-plan`, and `/flow:review-pr` skip the ledger.
- A deferred finding on a hotfix PR has two outcomes: a new issue (defects only), or skip.
- `/flow:commit-push-pr` reads the PR base line in the plan. It opens the PR against `main`.
- `/flow:finish-issue` sees the `main` base and runs its hotfix mode. It merges into `main`. It skips the release-notes update.
- If the PR base is wrong, `/flow:finish-issue` asks the user to retarget the PR or proceed as a hotfix.

### After the hotfix merges

1. Run the patch release with the project's deploy procedure. Get it with `flow-project-fact deploy`.
2. Merge `main` into the open milestone branch. The patch release ends with this merge.
3. Run `/clear`.
4. Type the command that `/flow:finish-issue` names. The command depends on the paused issue, if the hotfix issue has a `Paused for hotfix:` line:
   - The paused issue has an open PR: `/flow:address-pr-comments <paused-PR>`. The implementation finished. Do not run `/flow:start-issue` again.
   - The paused issue has no open PR: `/flow:start-issue <paused-N>`. It resumes the plan at its approval step, or tells the user to run `/flow:execute-plan`.
   - No `Paused for hotfix:` line: `/flow:start-issue <next>`.

The milestone work resumes after the patch release.
