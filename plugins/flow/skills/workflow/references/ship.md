# Ship

## Release when the theme is true

Release when the theme sentence is true. Do not wait for an empty list.

- If open issues remain and the theme is true, ship. Return the open issues to the backlog.
- If the list is empty and the theme is false, the milestone is not done.
- The user judges whether the theme is true. Ask the user.

## Finish the milestone

`/flow:finish-milestone <version>` gates the milestone branch. It runs these steps in order:

1. Lists the issues still open in the milestone. For each, the user chooses: finish it first, or remove it from the milestone.
   - If the user chooses to finish any issue, the command stops before it removes anything. Run the per-issue commands, then run `/flow:finish-milestone` again.
   - A removed issue loses its milestone and its `WIP:` release-notes entry.
2. Checks for leftover plan files.
3. Runs the `verify` command on the merged tree.
4. Runs `flow-check-milestone-scope-drift`. It compares the milestone's issues with the release notes.
5. Finalizes the release notes. Asks the retrospective questions.
6. Runs the `milestone_checks` command, if the key exists.
7. Updates the docs that the change needs.
8. Runs the cross-PR security check, a local multi-agent review, and a milestone-level deep review.
   - Each Medium or Low finding goes to the cleanup ledger (no behavior change) or to a new issue (a defect).
   - When build or install tooling changed, add a fresh-checkout smoke test.
9. Pushes `milestone/<version>` to `origin`.
10. Writes the completion marker `<version>-review.done` in the `plans` folder under `releases/`. The marker records the pushed commit.

## Review the milestone

`/flow:review-milestone <version>` checks the branch again. It stops in these cases:

- The release notes have a `WIP:` entry.
- The deploy sheet is missing.
- The marker is missing.
- The marker's commit is not the branch tip.

In each case, the user runs `/flow:finish-milestone <version>`.

When the checks pass, the command opens the PR to `main`. It reuses the PR if one is open.

It checks that the CI review posted and CI is green. `flow-verify-ci-review` accepts only a review with a verdict for the head commit.

- The command fixes a Blocking or Important finding on the milestone branch. `/flow:release-milestone` fixes nothing.
- After each fix passes `verify` and reaches the remote, move the marker's `sha:` line to the pushed commit.
- A commit that did not go through this loop needs `/flow:finish-milestone`.

## Release the milestone

`/flow:release-milestone <version>` checks these items before it merges:

- No Blocking or Important finding is open. If one is open, the command fixes nothing. It tells the user to run `/flow:review-milestone <version>`.
- The milestone scope matches the release notes.
- The version is newer than the last tag. Run `flow-check-version-newer <version>`.
- The deploy sheet is fresh.

After the user approves, `flow-release-milestone` merges the PR, tags the merge commit, creates a GitHub release, and closes the milestone. It removes the `milestone/*` branch.

The script reads the branch protection and the rulesets of `main` to choose the merge method:

- `main` requires linear history: a squash merge (`--squash`). `main` gets one commit for each release, so the tag and the commit are one-to-one.
- `main` does not require linear history: a merge commit (`--merge`).
- The plan has no branch protection (a private repo on GitHub Free): a merge commit.
- The script cannot read the branch protection or the rulesets for another reason: it exits 1 and changes nothing. The classic protection read needs admin read access.

The `release` key sets the release type:

- `publish`, or no key: the release is published and marked Latest.
- `draft`: the release is a draft. The deploy procedure publishes it.
- Any other value: the script exits 2 before the merge and the tag.

Run the `release_checks` command before the merge, if the key exists.

Deploy with the project's deploy procedure. Get it with `flow-project-fact deploy`. If the key is missing, ask the user.

Update the `release_notes` file in a PR before the release.

## Rerun the commands

- `/flow:finish-milestone` starts at the top after a stop or a branch change. It skips each step whose result exists for the current branch tip.
- A new commit runs the review steps again.
- The retrospective and a fresh deploy sheet are not redone.
- `/flow:release-milestone` skips the work it already completed. It does not repeat the merge, the tag, or the release.
- If the script stopped after the merge, the milestone branch and its release notes are gone. `/flow:release-milestone <version>` finds the merged PR and resumes at the tag step.
- `/flow:review-milestone` reuses an open PR.

## Retrospective

The retrospective has three questions. One line per answer is enough. Write the answers to `<version>-retro.md` in the `plans` folder under `releases/`.

1. What did we ship that nobody needed? Name the issue.
2. What did we learn about this theme's audience?
3. What signal arrived that we ignored, and was that right?

`/flow:plan-milestone` reads the newest retro file. Question 1 is the only feedback loop that improves the gate.
