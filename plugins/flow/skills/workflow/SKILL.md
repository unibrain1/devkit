---
name: workflow
description: "Milestone and issue workflow for /flow: commands. Load when a command cites it, or the user asks about next steps, reviews, the ledger, or backlog hygiene."
---

# Workflow

This skill holds the method for the `/flow:` commands. Each command file states its own steps. For its exact steps, the command file wins.

## Project facts

Read `.claude/project.md` before any step. Read one value with `flow-project-fact <key>`.

- If the file is missing, stop. Tell the user to run `/flow:setup`.
- If an optional key is missing, skip its step. Report the skip at the end.
- Never guess a project fact. Ask the user.

| Key | Use |
| --- | --- |
| `test`, `lint` | Required. Run before each commit and review. |
| `test_quick` | Optional. A faster test set during an issue. If it is missing, use `test`. |
| `verify` | Full verification. Run before a milestone review and release. |
| `deploy` | Deploy procedure. Ask the user if the key is missing. |
| `plans` | Plan folder. Git-ignored. Holds `issues/` and `releases/`. |
| `release_notes` | Release notes path pattern. `{version}` is the milestone version. |
| `ledger` | Cleanup ledger file. |
| `private_paths` | Paths that never enter a commit. |
| `issue_checks`, `milestone_checks`, `release_checks`, `milestone_setup` | Project commands at fixed steps. A non-zero exit stops the command. |

## Principles

1. Capture is free. Commitment is expensive.
2. A theme, not a list. Each milestone states one outcome for one audience.
3. Silence is a vote against. An idea that nobody asks about ages out.
4. The plan is the gate, not the diff. Approve the approach before the first line of code.
5. Test the path a user takes, and the failure that is silent. Test nothing else without a named reason.
6. Ship when the theme is true, not when the list is empty.

## Branch model

```text
main ← milestone/vX.Y.Z ← issue/NNN-slug
```

- One PR per issue. The PR targets the milestone branch.
- A hotfix branch starts from `main`. Its PR targets `main`.
- A milestone is in progress when its `milestone/*` branch exists on origin.
- Milestone limit: 1 in progress for a private repo, 2 for a public repo. Count with `flow-milestone-count --check`. Details: `references/plan.md`, "Milestone limit".
- `/flow:release-milestone` removes the milestone branch after the merge.

## Command order

```text
capture (any time)   /flow:new-issue          /flow:found (finds during an issue)
plan (per milestone) /flow:plan-milestone → /flow:start-milestone
build (per issue)    /flow:start-issue → /flow:execute-plan → /commit → /flow:review-pr
                     → /flow:commit-push-pr → /flow:address-pr-comments → /flow:finish-issue
ship (per milestone) /flow:finish-milestone → /flow:review-milestone → /flow:release-milestone
hotfix               see references/interrupts.md and the `hotfix` skill
```

- `/commit` is the `commit-commands:commit` skill.
- `/flow:groom-backlog` runs on demand during planning.
- `/flow:finish-milestone` reviews the milestone diff. Do not run `/flow:review-pr` at the milestone boundary.
- `/flow:execute-plan` runs the `/simplify` pass itself.

## Hand-offs between commands

A command's `model:` frontmatter applies only when the user types the command. A command that another command starts with the Skill tool runs on the starting command's model.

- Start the next command with the Skill tool only when both commands declare the same `model:`. Example: `/flow:start-issue` to `/flow:execute-plan`.
- Otherwise, tell the user to type the next command.
- At an issue or milestone boundary, recommend `/clear` first. Each turn re-reads the context. Earlier work raises the cost of every turn.

## The plan gate

- `/flow:start-issue <N>` writes the plan. The user approves it or sends it back.
- The plan needs three parts: `## Acceptance criteria`, a non-empty `## Not doing`, and `**Risk flag:**` set to `yes` or `no`.
- Work outside the approved plan stops `/flow:execute-plan`. The plan returns to `Draft`. The user must approve it again.
- The user reviews the diff only when the risk flag is `yes`.

Details: `references/build.md`.

## Section → file

| Section | File |
| --- | --- |
| Project facts, Principles, Branch model, Command order, Hand-offs between commands, The plan gate | This file |
| `1. Capture`, `The signal records origin, not every later measurement`, `What an issue records at capture`, `The occasional contributor` | `references/capture.md` |
| `2. Plan`, `Pick the theme`, `Gate each candidate`, `Edge-case test`, `Seal the milestone`, `Planning agents`, `Unsealed milestone`, `Issue order and blockers`, `Milestone limit` | `references/plan.md` |
| `The plan gate`, `Plan rules`, `Execute the plan`, `Deviation`, `Delta from plan`, `Merge an issue`, `Discoveries mid-issue`, `Test tier rules`, `Definition of done` | `references/build.md` |
| `Review and CI`, `One review round`, `Two-round ceiling`, `Severity contract`, `The local gate is the CI gate`, `CI review is a backstop`, `The test suite is production code` | `references/review.md` |
| `Ship`, `Release when the theme is true`, `Finish the milestone`, `Review the milestone`, `Release the milestone`, `Rerun the commands`, `Retrospective` | `references/ship.md` |
| `Interrupts and the hotfix track`, `Entry points`, `Save the paused work`, `Hotfix rules`, `After the hotfix merges` | `references/interrupts.md` |
| `Backlog hygiene`, `Age-out with evidence rescue`, `Age from creation, not from last activity`, `Gate-critical issues bypass the theme test`, `Run the sweep`, `Tracking` | `references/backlog.md` |
| `gh CLI gotchas`, `Labels`, `Milestones`, `Comment markers`, `Settings` | `references/github.md` |
| `Plan files`, `Plan header`, `Plan sections`, `Cleanup ledger`, `Release notes` | `references/plans-and-ledger.md` |
| `The main-match rule`, `Workflow parity`, `Edit a caller only at a milestone boundary`, `Caller interface` | `references/ci-main-match.md` |
| `Where am I? What do I run next?` | `references/next-step.md` |
