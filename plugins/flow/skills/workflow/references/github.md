# GitHub

## gh CLI gotchas

Get the repo with `flow-repo`. Use `flow-repo --visibility` for `PUBLIC`, `PRIVATE`, or `INTERNAL`. Do not write the owner or name by hand.

- `gh milestone list` does not exist. Use `gh api repos/$(flow-repo)/milestones`.
- `gh issue list --milestone` can return an empty list with no error. Use the direct API:

```bash
gh api "repos/$(flow-repo)/issues?milestone=<number>&state=open"
```

## Labels

`/flow:setup` creates the missing labels from `templates/labels.tsv`, after the user approves the list. Run `flow-labels --missing` to see them.

| Label | Meaning |
| --- | --- |
| `signal:owner`, `signal:analytics`, `signal:operator`, `signal:defect`, `signal:forced`, `signal:discovered` | Signal. Exactly one per issue. See `capture.md`. |
| `triage` | Captured, not planned. Removed at planning. |
| `bug`, `enhancement` | Issue type at capture. |
| `status:ready` | Planned and approved for a milestone. Needs acceptance criteria. |
| `status:blocked` | Waits on a blocker. Set and removed by hand. |
| `gate-critical` | Standing gate depends on it. Bypasses the theme test. See `backlog.md`. |
| `stale`, `stale-no-demand` | Age-out. See `backlog.md`. |
| `help-wanted` | Open to the occasional contributor lane. See `capture.md`. |
| `component: security` | Security work. Exempt from age-out. |

## Milestones

- The milestone description states the goal. It does not list issue numbers.
- A milestone holds open work and shipped work only. Remove the milestone from an issue that closes as `not planned` or `duplicate`.
- The title of a release milestone starts with the version.

## Close reasons

Each `gh issue close` in the flow commands gives a reason. With no reason, GitHub records `completed`, also for work that did not ship.

| Reason | Flag | Meaning | Milestone |
| --- | --- | --- | --- |
| `completed` | `--reason "completed"` | The work shipped. Only `/flow:finish-issue` runs `gh issue close` with it. | The issue keeps it. |
| `not planned` | `--reason "not planned"` | A cull: the issue fails the planning gate, the grooming sweep, or the age-out. | Remove it in the same step. |
| `duplicate` | `--duplicate-of <N>` | A consolidation: issue `<N>` keeps the work. | Remove it in the same step. |

`tests/commands/test-issue-close-reasons.sh` fails when a close in `plugins/flow/commands/` has no reason, or when a cull close has no milestone step directly before it.

## Comment markers

The flow commands read these comments. Write them in this exact form.

| Comment | Meaning |
| --- | --- |
| `Combine into one PR with #A, #B (planned in <version>).` | The issues land as one PR. `/flow:start-issue` asks whether to plan the combined scope. |
| `Blocked by #X (planned in <version>).` | The issue waits on the named blocker. |
| `Marked stale: <reason>` | The age-out warning. It does not count as a rescue. |
| `Paused for hotfix: #<N>` (in the hotfix issue body) | Names the paused issue. `/flow:finish-issue` uses it to name the next command. |

## Settings

The project's `.claude/settings.json` denies the plugin skill `commit-commands:commit-push-pr`. Then `/flow:commit-push-pr` is the only PR command. The plugin skill does not write the PR body sections that `/flow:finish-issue` reads: risk flag, delta from plan, and review decisions.
