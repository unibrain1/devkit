# Plan

## 2. Plan

`/flow:plan-milestone <version>` runs one planning session per milestone. The session takes about 30 minutes. It ends with a sealed milestone.

### Pick the theme

- Read the signals since the last planning: user contacts, analytics anomalies, error logs, new backlog issues.
- Find the theme in the signals. Do not invent it.
- Read the newest retrospective file in the `plans` folder under `releases/` (`<version>-retro.md`). Show its answers before the user picks the theme.
- The first retro answer raises the bar. A candidate of the same kind needs a stronger signal.

A theme is one sentence. It names an audience and an outcome.

- Good: "A customer can export their invoices without emailing support."
- Bad: "Invoice improvements." It has no audience and no outcome.

A sentence that cannot take this form is a category. Categories never end. Pick again.

A candidate is an open issue with no milestone. An issue in a milestone is not a candidate.

If no open milestone has the version, offer to create it. The title must start with the version.

### Gate each candidate

Each candidate must pass all three questions:

1. Who noticed? Name the signal. If the answer is "nobody, I thought of it", the issue is out.
2. What do they do today instead? If the workaround is acceptable, the issue is not a release item.
3. What breaks if this never ships? If nothing breaks, close the issue and say so in it.

A user-visible `signal:defect` skips questions 1 to 3 and the edge-case test. It counts toward the theme issues.

A `signal:defect` that no user can see passes the gate like any other candidate.

### Edge-case test

Apply this test to each candidate. Apply it again to each branch in its plan.

> How many real users take this path in a year? If we do not handle it, does it fail gracefully or badly?

| Users | Failure | Action |
| --- | --- | --- |
| Many | Badly | Build it. |
| Few | Badly | Build the guard, not the feature. A clear error beats a code path for three people. |
| Few | Gracefully | Do not build it. Record the decision in the plan. |

### Seal the milestone

A milestone contains:

- 3 to 6 theme issues. A user-visible `signal:defect` counts here.
- At most 1 housekeeping issue. It has `signal:forced` and fits no theme.
- Every open `gate-critical` issue. These do not count against the housekeeping slot.
- Nothing else.

`/flow:plan-milestone` then does this:

1. Writes the theme sentence into the milestone description. It does not write an issue list.
2. Writes acceptance criteria into each selected issue. The criteria go in an `## Acceptance criteria` section of `- [ ]` lines. An issue without this section does not get `status:ready`.
3. Changes the title prefix from `bug:` to the type of work that ships (`fix:`, `feat:`, and so on).
4. Assigns the milestone, adds `status:ready`, and removes `triage`.
5. For an issue the edge-case test scoped down, posts a comment that states the reduced scope. The criteria cover the guard only.
6. For issues that must land as one PR, posts `Combine into one PR with #A, #B (planned in <version>).` on each issue of the group. The user approves the groups first.
7. Closes a cut candidate that failed all three questions. Any other cut candidate stays in the backlog with one comment that gives the reason.

### Planning agents

For milestone planning, run `senior-product-manager`, `senior-architect`, and `security-reviewer` in parallel. Each analyzes the work.

### Unsealed milestone

`/flow:start-milestone` runs on a milestone that `/flow:plan-milestone` did not seal. It applies a lighter gate. Use it when the milestone description is a theme sentence and every open issue has `status:ready`.

The lighter gate does this for each issue that stays:

- Writes the acceptance criteria.
- Gives the title its scoped type.
- Adds `status:ready` and removes `triage`.

`/flow:start-issue` needs these marks.

### Issue order and blockers

`/flow:start-milestone` recommends an issue order. The user approves it. Then the command writes the order into the `release_notes` file. The `WIP:` entries under "Issues Resolved" follow the approved order.

The command also writes these facts on GitHub:

- A combine group: the comment `Combine into one PR with #A, #B`. `/flow:start-issue` reads it.
- An order conflict: the `status:blocked` label, and the comment `Blocked by #X (planned in <version>).` on the issue that must wait.

`/flow:finish-issue` picks the next issue. It picks the first `WIP:` entry whose issue is open and not `status:blocked`. If no entry matches, it picks the lowest-numbered open issue without that label.

To change the order, move the entries in the release notes. Commit the change.

`/flow:finish-issue` reminds the user to remove `status:blocked` when a blocker closes. It never removes the label itself. The issue can have other blockers.

### Milestone limit

Count milestones in progress before a new milestone starts.

- A milestone is in progress when its `milestone/*` branch exists on origin.
- Open GitHub milestones are plans. They do not count.
- Run `flow-milestone-count --check`. It counts the `milestone/*` branches on origin.
- Limit: 1 for a private repo, 2 for a public repo.
- At the limit, `/flow:start-milestone` stops.
- `/flow:release-milestone` removes the `milestone/*` branch after the merge. A branch that stays keeps the count up.
