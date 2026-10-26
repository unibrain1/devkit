# Plans and ledger

## Plan files

The `plans` key names the plans folder. The folder must be git-ignored.

- Never commit a file in the `plans` folder.
- Remove a plan file with `rm`. Do not use `git rm`.
- `issues/` holds one plan per issue: `issues/issue-<NNN>-<slug>.md`.
- `releases/` holds the release files: `<version>-retro.md` and the review marker `<version>-review.done`.
- The `private_paths` key lists paths that must never enter a commit. A guard hook and `/flow:commit-push-pr` block them.

### Plan header

| Field | Values |
| --- | --- |
| Status | `Draft — pending approval`, `Approved — ready for /execute-plan`, `Implemented — pending commit/PR`. `flow-check-plan-state` matches the approved text exactly. |
| Risk flag | `**Risk flag:** yes` or `**Risk flag:** no`. See `build.md`, "The plan gate". |
| Milestone | The milestone name, or `none (hotfix)` |
| PR base | The branch the PR targets. `main` for a hotfix. |

### Plan sections

| Section | Content |
| --- | --- |
| `## Acceptance criteria` | `- [ ]` lines. Copied from the issue. |
| `## Not doing` | Refused edge cases and nearby ideas. At least one line. |
| `## Implementation Checklist` | The work items. Ticked as done. |
| `## Ledger items` | Open ledger items for the files the plan edits. |
| `## Found in passing` | Finds fixed in this PR. Also `Considered, dropped: <reason>` lines. |
| `## Deviation` / `## Approved deviation` | See `build.md`, "Deviation". |
| `## Review decisions` | Declined review findings. See `review.md`. |
| Review fingerprint line | Written by `flow-review-fingerprint`. Names the clean review lanes. |

## Cleanup ledger

The `ledger` key names the cleanup ledger file. A cleanup find does not get its own issue. It goes in the ledger.

The ledger has one heading per file. Each open item is one `- [ ]` line under its file heading.

- Add an item: edit the file. Put the line under the file heading. Add the heading in path order if none exists. Do not add an item whose text already exists. Put the edit in the PR of the current branch.
- Fix an item: remove its line in the PR that fixes it. Remove the file heading too, when no items remain. The file holds no `- [x]` lines. Git history is the record.
- Find the items for a change: `git diff --name-only <base>..HEAD | flow-ledger-items-for-files`. It prints `path: item text`.
- Move or remove a file only with its ledger group. Remove the file heading in the same change.
- Drop a cleanup find that has no named benefit. Do not record it. `/flow:found` writes `Considered, dropped: <reason>` in the plan. A later review then does not raise the find again.

Each command uses the ledger at one step:

| Command | Ledger action |
| --- | --- |
| `/flow:found` | Adds a cleanup find with an edit. |
| `/flow:start-issue` | Copies the items for each file the plan edits into `## Ledger items`. The plan gate approves them. Skipped for a hotfix. |
| `/flow:execute-plan` | Removes the line of each item it fixes, and ticks it in the plan. Checks the edited files for items the plan does not list. For each one, offers: fix now, add to the plan and fix, or leave. Checks that no ticked item remains in the file. Skipped for a hotfix. |
| `/flow:review-pr` | Reports each open item for a changed file as a Recommendation. Fix now removes the line. Defer on a ledger item records `Deferred: ledger` and changes nothing. Other deferred findings go to a new issue (defect) or to the ledger (cleanup). |
| `/flow:commit-push-pr` | Information only. Lists the open items for the touched files in its final summary. |
| `/flow:address-pr-comments` | Removes the line of an item that one of its fixes completes. Commits the ledger edit with the fixes. A deferred Advisory item goes to a new issue (defect) or the ledger (cleanup). |
| `/flow:finish-issue` | Information only. Reports the open items that remain in the files the PR edited. |

## Release notes

The `release_notes` key gives the path pattern. `{version}` is the milestone version.

- `/flow:start-milestone` writes the draft release notes. Each issue has a `WIP:` prefix under "Issues Resolved". The order of the entries is the approved issue order.
- `/flow:execute-plan` fills in each issue's real changes.
- `/flow:finish-issue` removes that issue's `WIP:` prefix when its PR merges.
- `flow-check-wip-markers` finds any `WIP:` prefix left in the release notes. `/flow:review-milestone` stops when a `WIP:` entry remains.
- `flow-check-milestone-scope-drift` compares the release notes with the milestone's current issues.
