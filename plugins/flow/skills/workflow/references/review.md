# Review

## Review and CI

Review runs once, on a finished artifact, before the push. Each review pass stays in the workflow. The review fingerprint stops a pass from running twice on the same code.

## One review round

- `/flow:execute-plan` runs the `/simplify` pass first.
- It then runs every applicable reviewer in parallel, against the same commit, before the push.
- Reviewers include: code review, test analysis, silent-failure, comment, type-design, UX, architecture, and security.
- Collect every finding into one list. Triage it once. Fix it in one commit. Then push.
- Give reviewers the plan's claims as claims to check. Do not give them as facts.

When the round is clean, `flow-review-fingerprint` records a fingerprint of the branch in the plan file. The fingerprint names the lanes that reported no Blocking finding: `code-reviewer`, `silent-failure-hunter`, `comment-analyzer`, and `pr-test-analyzer`.

`/flow:review-pr` runs the same agents on the full branch diff.

- It refuses uncommitted changes. Run `/commit` first.
- It skips each lane that the fingerprint names, when the branch has the same fingerprint.
- The `spec` lane, the `simplify` aspect, and the verification suite always run.
- When the review is clean and no fix changed a file, it writes a new fingerprint.

## Two-round ceiling

- After a fix commit, check only the fix. Use its own diff and only the reviewers whose findings it addressed. That is round two.
- A fresh agent, not the author's session, triages round two.
- A third round means the plan was wrong. Stop patching.
- Return to the plan gate and re-scope. `/flow:execute-plan` asks the user to choose one:
  - Re-scope the plan.
  - Split the rest into a follow-up issue.
  - Keep fixing, with a stated reason.

## Severity contract

Every reviewer, local or CI, sorts each finding into one bucket.

| Bucket | Test | Action |
| --- | --- | --- |
| Blocking | Verified, reproducible, and in this diff | Fix now, in this PR. |
| Advisory | Real, but not this PR's job | New issue (defect, `signal:discovered`) or cleanup ledger (no behavior change). |
| Note | Wording, style, docs nuance | Fix only if the change already touches that line. |

Record each declined finding under `## Review decisions` in the plan. Use one of these forms:

```text
- `<file:line>` — <issue> — False positive: <reason>
- `<file:line>` — <suggestion> — Skipped: <reason>
- `<file:line>` — <suggestion> — Deferred: ledger | issue #<n>
```

- `/flow:review-pr` asks about one Recommendation at a time. It writes a line for each deferred or skipped item. It also writes a line for each Blocking item the user rules a false positive.
- When a PR exists, `/flow:review-pr` also writes the line to the PR body.
- `/flow:commit-push-pr` copies the plan section into a new PR body.
- `/flow:address-pr-comments` writes the same lines to the PR body for each Blocking false positive, and for each Advisory item the user defers or skips.

## The local gate is the CI gate

A change that passes locally and fails in CI means the two gates differ. Treat the difference as a defect in the gates. Close the gap. Do not retry CI.

- The `lint` and `test` commands run locally before a review.
- Run the project's full `verify` command before a milestone review or release.

## CI review is a backstop

- The CI review on an issue PR is a second opinion. Local reviewers already saw the code.
- The CI review on a milestone PR to `main` is the deep review. It blocks.
- A CI Blocking finding follows the same test as any other finding. It must be verified, reproducible, and in this diff.

## The test suite is production code

- A spec that fails for a non-product reason is a defect in the suite. It is not a flake.
- Fix it in the same PR when it blocks the PR. File it as `signal:defect` when it does not.
- Assert the expected count of collected tests. A suite that collects nothing must fail.
- Suite fixes bypass the theme test. See `backlog.md`, "Gate-critical issues bypass the theme test".
