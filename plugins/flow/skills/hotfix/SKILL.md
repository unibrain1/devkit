---
name: hotfix
description: "Run the hotfix procedure for a production emergency: production is broken, data is at risk, or a security exposure exists. Use when the user starts a hotfix or asks how to handle an urgent production defect."
---

# Hotfix

Use this procedure when production is broken, data is at risk, or a security
exposure exists.

1. Capture the issue with `/flow:new-issue` (`signal:defect`). During another
   issue, use `/flow:found`, which records the paused issue.
2. Run `/flow:start-issue <N> --hotfix`. It branches from `main`. The
   per-issue commands then run as usual, with PR base `main`.
   - If the project has a `milestone_setup` key, the app holds its own
     version. In the hotfix PR, set that version by hand to the next patch
     version: the newest `vX.Y.Z` tag on `origin/main`, with the patch
     number plus one. Change the same file that `milestone_setup` writes.
   - Do not run `milestone_setup`. It reads the version from a milestone
     branch name, and a hotfix branch has no version in its name.
3. After `/flow:finish-issue` merges the PR, tag the patch release:
   `flow-release-hotfix <PR>`. It tags the merge commit with the next patch
   version and creates the GitHub release. In a container repo, the tag
   moves the image tag `latest`. Run it with `--dry-run` first to see the
   tag. If the project's deploy procedure makes its own hotfix tag, remove
   that tag step from the deploy procedure first. `flow-release-hotfix`
   makes the tag.
4. Deploy the patch release with the project's deploy procedure. Get it
   with `flow-project-fact deploy`. If the project has no `deploy` key, ask
   the user for the procedure. Do not guess.
5. Merge `main` into the open milestone branch, if one exists. The patch
   release ends with this merge.
6. To resume a paused issue, type `/flow:start-issue <paused-N>`.
   `/flow:finish-issue` names it.

The rules for the hotfix track are in the `flow:workflow` skill,
`references/interrupts.md`.
