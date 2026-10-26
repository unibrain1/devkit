# Where am I? What do I run next?

Each command stores its state in GitHub, the repo, or the plan file. The user can stop at any point, run `/clear`, and continue.

Find the current state in the first column. Run the command in the second column. Check the third column before the next run.

The user types the command. A command starts the next command only under the hand-off rule in `SKILL.md`, "Hand-offs between commands".

| State | Run next | `/clear` first? |
| --- | --- | --- |
| New release to plan | `/flow:plan-milestone <version>` | Yes |
| Milestone sealed, no branch | `/flow:start-milestone <version>` | Yes |
| Milestone branch exists, issue is `status:ready` | `/flow:start-issue <N>` | Yes, at an issue boundary |
| Plan stopped before approval (plan `Draft`) | `/flow:start-issue <N>`. It resumes at the approval step. | No, unless the session holds another issue |
| `/flow:execute-plan` stopped on a deviation (plan back to `Draft`) | `/flow:start-issue <N>`, then `/flow:execute-plan <N>` | No |
| Plan `Approved` | `/flow:execute-plan <N>` | Optional. The plan file holds the state. |
| `/flow:execute-plan` stopped part way | `/flow:execute-plan <N>`. It re-checks the checklist against the repo. | No |
| Plan `Implemented`, work uncommitted | `/commit` | Optional |
| Work committed, not reviewed | `/flow:review-pr` | Optional. The plan file holds the state. |
| Review clean | `/flow:commit-push-pr` | Yes |
| `/flow:commit-push-pr` stopped | `/flow:commit-push-pr`. Safe to run again. It reuses an open PR. | No |
| PR open, CI and automated review running | `/flow:address-pr-comments` after they post | Yes |
| `/flow:address-pr-comments` stopped (CI red, or checks still running) | Fix the cause, then `/flow:address-pr-comments` | No |
| PR clean | `/flow:finish-issue <N>` (the issue number, not the PR number) | Yes |
| `/flow:finish-issue` stopped (CI red, risk flag, failed step) | Fix the cause, then `/flow:finish-issue <N>`. If the PR already merged, it continues at the close step. | No |
| User answered `Stop` at the merge confirmation | `/flow:finish-issue <N>` when ready to merge. Nothing merged. | No |
| Hotfix merged | The patch release (`deploy` key). Then the command that `/flow:finish-issue` names. See `interrupts.md`. | Yes |
| Issue merged, open issues remain | `/flow:start-issue <next>` | Yes |
| Issue merged, every open issue blocked | Remove `status:blocked` from an issue whose blocker closed, then `/flow:start-issue <N>`. If the blocked issues can wait, `/flow:finish-milestone <version>`. | Yes |
| Issue merged, no open issues remain | `/flow:finish-milestone <version>` | Yes |
| `/flow:finish-milestone` stopped, or the branch changed | `/flow:finish-milestone <version>`. It skips each step whose result matches the branch tip. | No |
| `/flow:finish-milestone` done | `/flow:review-milestone <version>` | Yes |
| `/flow:review-milestone` says the review marker is old | `/flow:finish-milestone <version>` | No |
| `/flow:review-milestone` stopped after the PR opened | `/flow:review-milestone <version>`. It reuses the open PR. | No |
| Milestone PR green | `/flow:release-milestone`. `/flow:review-milestone` can start it. If `release_checks` fails, fix it by hand first. Then `/clear`. Then `/flow:release-milestone`. | No |
| `/flow:release-milestone` stopped before the merge | Fix the cause, then `/flow:release-milestone <version>`. It skips the steps it already completed. | No |
| `/flow:release-milestone` stopped after the merge | `/flow:release-milestone <version>`. It finds the merged PR and resumes at the tag step. | No |
| Release created | Deploy with the `deploy` procedure. Then `/flow:plan-milestone` for the next release. | Yes |
| Production broken, no issue in progress | `/flow:new-issue` (`signal:defect`). Its last step names `/flow:start-issue <N> --hotfix`. | Yes |
| Production broken, issue in progress | `/flow:found`. Save the paused work on its branch. Then `/clear`. Then `/flow:start-issue <N> --hotfix`. | After the user saves the work |
