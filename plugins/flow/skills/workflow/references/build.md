# Build

## 3. Build

Build works one issue at a time. The plan approval is the human checkpoint. The diff is not reviewed by default. The exception is in "Risk flag" below.

## The plan gate

`/flow:start-issue <N>` researches the issue and writes a plan file. The user approves the plan or sends it back.

### Readiness check

Before planning, `/flow:start-issue` checks the issue. The issue needs three marks: a milestone, the `status:ready` label, and an `## Acceptance criteria` section.

| Missing | Action |
| --- | --- |
| Milestone | Stop. Name `/flow:plan-milestone <version>`. |
| `status:ready`, but the issue is in a release milestone | Ask the user. Stop and run `/flow:start-milestone <milestone>`, or write the criteria at the plan gate. |
| Only the section | Ask the user. Write the criteria at the plan gate, or stop and add the section to the issue body. |

A hotfix skips this check.

### Plan rules

The plan names the problem, the approach, the files, the tests, the data and security concerns, and the checklist. The command enforces each rule below.

- Acceptance criteria: an `## Acceptance criteria` section of `- [ ]` lines. The command copies them from the issue. If the issue has none, the command writes them and posts them to the issue body on approval. No approval while the section is empty.
- Not doing: a `## Not doing` section with at least one line. It lists the edge cases and nearby ideas that the plan refuses. No approval while the section is empty.
- Risk flag: the header has `**Risk flag:** yes` or `**Risk flag:** no`. Set `yes` when the change touches auth, sessions, or permissions, a database migration, an API endpoint contract, or payments.
- Risk flag review: `/flow:commit-push-pr` copies the flag into the PR body. `/flow:finish-issue` reads it. When the flag is `yes`, `unknown`, or missing, the user must answer `I reviewed the diff` before merge. This is the only case where the user reviews the diff.

If the issue is in a combine group, `/flow:start-issue` asks whether to plan the combined scope. One branch, one plan, and one PR cover all the issues. The plan header records the choice.

### Execute the plan

After approval, `/flow:execute-plan` builds the work. It does this in order:

1. Checks the plan checklist against the repo.
2. Implements the checklist. Runs parallel work where the plan allows.
3. Writes and runs tests. Each new test must fail with the change reverted. The plan file records the result.
4. Runs the `issue_checks` command, if the key exists. Checks the cleanup ledger for the edited files.
5. Updates the draft release notes. Skip this step for a hotfix.
6. Runs the `/simplify` pass. The review in the next step then checks the simplified code.
7. Runs one review round. Records the review fingerprint.
8. Sets the plan status to `Implemented — pending commit/PR`.

`/flow:execute-plan` never commits, pushes, or opens a PR. It ends by telling the user to type `/commit`, then `/flow:review-pr`. `/flow:review-pr` refuses uncommitted changes.

### Deviation

Work outside the approved plan is a deviation. It includes a file the plan does not list, a different approach, a dropped requirement, or a new dependency.

When a deviation appears, `/flow:execute-plan` stops:

1. It adds a `## Deviation` section to the plan. It does not edit the checklist.
2. It posts a comment on the issue that states the deviation and asks for re-approval.
3. It sets the plan status to `Draft — pending approval`.
4. It leaves the work uncommitted.

The user types `/flow:start-issue <N>`. The command shows the deviation and resumes at the approval step. There it:

1. Merges the deviation items into `## Implementation Checklist`.
2. Pulls the ledger items for the files the deviation adds.
3. Sets the risk flag again over all files. It does not change `yes` to `no` without the user's answer.
4. Renames `## Deviation` to `## Approved deviation` when the user approves.

The user then types `/flow:execute-plan <N>`.

### Delta from plan

`/flow:commit-push-pr` writes `## Delta from plan` in the PR body. It lists files the plan did not list, checklist items marked N/A, or `none`.

An N/A item keeps its `[ ]` and ends with this form:

```text
- [ ] <item> — N/A: <reason>
```

## Merge an issue

`/flow:finish-issue` runs its steps in a fixed order. It skips no step.

1. Reads the CI results. A red check stops the command.
2. Runs the `issue_checks` command, if the key exists.
3. Reads the risk flag. A `yes`, `unknown`, or missing flag needs the user's answer. See "Risk flag review".
4. Asks for the merge confirmation: `Merge` or `Stop`.
5. Squash-merges the PR. Merges only when the user answered `Merge` in the same run.

If the PR changes a CI review workflow file, the review cannot post before the merge. The command asks the user to choose `Proceed without the CI review` or `Stop`. Without that approval, the PR does not merge.

After the merge, the command picks the next step. See `next-step.md`.

## Discoveries mid-issue

Run `/flow:found <description>` when a pre-existing problem appears during an issue. It classifies the find by containment and class.

| Containment | Class | Action |
| --- | --- | --- |
| In scope | Needed for the acceptance criteria | Fix it in this PR. Note it under **Found in passing** in the plan. |
| In scope | Not needed, defect | New issue, `signal:discovered`. |
| In scope | Not needed, cleanup | Cleanup ledger. |
| Out of scope | Production broken, data at risk, or security exposure | Hotfix track. See `interrupts.md`. |
| Out of scope | Not an emergency, needed for the acceptance criteria | Deviation. `/flow:execute-plan` stops and re-gates the plan. |
| Out of scope | Anything else, defect | New issue, `triage` label, no milestone. |
| Out of scope | Anything else, cleanup | Cleanup ledger. |

- Fix size is not a test. Fix a defect in this PR only if the acceptance criteria need it.
- A defect gives a user or an operator a wrong result. Examples: a wrong value, lost data, a failed request, a missing email.
- Cleanup changes no behavior. Examples: dead code, duplication, naming, comments, type annotations.
- `/flow:start-issue` applies the same table to what its exploration finds.

## Test tier rules

Each change type has a standing test obligation. Do not negotiate coverage per issue.

| Change type | Required | Not required |
| --- | --- | --- |
| Domain logic | A unit test per behavior in the acceptance criteria | Input permutations that reach the same branch |
| Bug fix | One regression test that reproduces the report | Tests for adjacent behavior |
| New or changed API endpoint | Integration test: happy path and auth-failure path | Every validation permutation |
| New page or route | End-to-end smoke test: loads, access control works, no console errors | Full interaction coverage |
| Auth, CSRF, input handling | The negative case, always | — |
| Database migration | Integration test against the migrated schema. Rollback verified. | — |
| UI copy, CSS, layout | None | — |
| Refactor with no behavior change | None new. The existing suite stays green. | — |

- Write one test per acceptance criterion. Add the negative case for any security-related change.
- Any other test needs a named reason in the plan.
- Never test a branch that a real user cannot reach.
- Each new test must fail with the change reverted. `/flow:execute-plan` records this.
- Run the `test` command before the PR opens. Report the real output.
- During an issue, run the `test_quick` command for fast feedback. If the key is missing, run `test`. The full `test` command always runs before the PR opens.

## Definition of done

An issue is done when all of these hold:

- The acceptance criteria are met. Show the evidence.
- Tests exist per the tier rules, and they pass.
- CI is green.
- The change updates the docs that it touches.
- The PR body has a `## Delta from plan` section.
- When the risk flag is `yes`, the user reviewed the diff.
