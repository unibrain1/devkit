# Backlog

## Backlog hygiene

Free capture makes the backlog grow faster than it drains. Old ideas start to look like commitments. These rules keep the backlog small.

`/flow:groom-backlog` applies these rules on demand. It proposes each action. It changes nothing until the user approves.

### Age-out with evidence rescue

- Warn: an open issue created more than 180 days ago, with no human comment in that time, gets the `stale` label. Add a comment that starts with `Marked stale:`.
- Close: an issue with the `stale` label for 14 days or more, and no human comment since the label, closes as `stale-no-demand`. The comment says that silence counts as a vote against. It says that a new signal reopens the issue.
- Remove the label: an issue that is now exempt, or has a human comment since the label, loses `stale`.
- Exempt: any issue in a milestone. Any issue with `signal:forced`, `component: security`, or `gate-critical`.
- Rescue: a new signal reopens the issue with the new evidence attached. A user asks, or analytics show the gap. The issue takes the new signal's label.
- `/flow:new-issue` finds a closed `stale-no-demand` match and offers the rescue. The rescue reopens the issue. It posts the evidence as a comment. It swaps the old signal label for the new one. It removes `stale` and `stale-no-demand`.

### Age from creation, not from last activity

- Age an issue from `created_at`.
- Label, milestone, and title changes are not activity. Bulk housekeeping resets `updated_at`.
- Only a human comment or a new signal counts as a rescue. A bot comment does not. The `Marked stale:` warning does not count.

### Gate-critical issues bypass the theme test

Two kinds of work skip the theme gate: `signal:forced` work, and work that a standing gate depends on. Mark the second kind with the `gate-critical` label.

- Apply `gate-critical` by hand. No signal implies it.
- `gate-critical` issues are exempt from age-out, like `signal:forced`.
- The label is the list. Find the open issues with `gh issue list -R "$(flow-repo)" --label gate-critical --state open`.

### Run the sweep

`/flow:groom-backlog` sweeps the open issues. It does this:

- Applies the three planning questions from `plan.md`.
- Skips the exempt issues.
- Recommends closures and target milestones.
- Proposes the age-out actions.
- Acts on one approval from the user.

It never moves an issue into a release milestone. Only `/flow:plan-milestone` adds an issue to a release, after its gate.

For an issue in the backlog, the sweep suggests a target milestone. It ends with a pointer to `/flow:plan-milestone <version>`.

The sweep removes an issue from a milestone only when all of these are true:

- The issue has no branch and no open PR.
- Its milestone is not active.

It also removes `status:ready` in that case.

The sweep does not edit the cleanup ledger.

A project command, if the project has one, reviews the test suite. Run it before `/flow:groom-backlog`.

## Tracking

GitHub holds the state. The state is the milestone, the derived state, and one manual label. Do not keep a board or a state file. A second source of truth decays.

| State | Shown by |
| --- | --- |
| Backlog | Open, and no milestone |
| Ready | In the open milestone, `status:ready`, no branch |
| In progress | A branch exists for the issue |
| In review | A PR is open |
| Blocked | `status:blocked` label. The only state that the user sets by hand. |
| Done | Closed |

- Blocked is the only state that git cannot show. Name the blocker in a `Blocked by #X` comment.
- Name a combine group in a `Combine into one PR with #A, #B` comment.
- A project command, if the project has one, renders the status view. The view changes nothing.
