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
3. Do the patch release with the project's deploy procedure. Get it with
   `flow-project-fact deploy`. If the project has no `deploy` key, ask the
   user for the procedure. Do not guess.
4. Merge `main` into the open milestone branch, if one exists. The patch
   release ends with this merge.
5. To resume a paused issue, type `/flow:start-issue <paused-N>`.
   `/flow:finish-issue` names it.

The rules for the hotfix track are in the `flow:workflow` skill,
`references/interrupts.md`.
