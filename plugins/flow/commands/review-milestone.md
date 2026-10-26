---
description: Open the milestone PR, verify CI review posted, and confirm CI is fully green
model: sonnet
---

# Review Milestone

Keep output brief — terse status lines, no preamble, no restating of steps.

Open the PR for a gated milestone branch, verify the CI milestone-level
review actually posted a comment, and drive any Blocking/Important findings
to resolution before the branch is handed off to `/flow:release-milestone`.

This command picks up where `/flow:finish-milestone` left off — after the
milestone branch has been tested (Step 3.7 there), reviewed (Steps 9.5–9.9
there), documented (Steps 5.5–6 there), and pushed (Step 10 there).

The method is in the `flow:workflow` skill, `references/ship.md`, "Review
the milestone".

The user can type `/flow:review-milestone $ARGUMENTS` again after a run
stops. Step 3 reuses an open milestone PR, and Step 1 accepts the fix
commits that Step 4 pushed.

## Arguments

- `$ARGUMENTS` — the milestone version number (e.g., `v2.17.0`)

## Important

- **Closing keywords are critical** — without them in the PR body, issues
  won't auto-close on merge. Use them only for issues that a merged PR
  resolved
- The PR MUST target `main`, not any other branch
- Push only `milestone/$ARGUMENTS`, only to `origin`, and only for finding
  fixes in Step 4. After each verified fix push, Step 4 moves the marker's
  `sha:` line to the new tip. Never push `main`
- This command does not finalize release notes. That is
  `/flow:finish-milestone`'s responsibility. If Step 1 finds any of that
  incomplete, send the user back there rather than doing it here.

## Step 0: Project facts

1. Run `flow-project-check`. If it fails, show its output. Tell the user to
   fix `.claude/project.md` or run `/flow:setup`. Stop.
2. Read each fact that this command needs with `flow-project-fact <key>`:
   `plans`, `release_notes`, `milestone_checks`, `verify`.
3. If `plans` is absent, stop. Tell the user: "This command reads the review
   marker in the `plans` folder. Add the `plans` key to
   `.claude/project.md`."
4. Call `<plans>/releases` the `RELEASES` folder. Replace `{version}` in the
   `release_notes` value with `$ARGUMENTS`. Call the result `NOTES_PATH`.
5. Run `flow-repo`. Keep the result as `REPO`. Use `$REPO` in each command
   below.
6. If another key is absent, add its step to the skipped list when you reach
   that step.

## Workflow

### Step 0a: Initialize TaskList

Before any other action, create one tracking task per workflow step using
TaskCreate:

1. Locate the milestone branch and re-verify it's review-ready
2. Re-derive merged-PR list, diff, and milestone-check status
3. Create the PR targeting main, or reuse the open one
4. Verify CI milestone review posted with zero unresolved findings; recover
   and fix as needed; confirm CI is fully green
5. Output summary

Set each task to `in_progress` when you begin it and `completed` on success.

### Step 1: Locate the milestone branch and re-verify it's review-ready

```bash
git branch -a | grep "milestone/$ARGUMENTS"
git status --porcelain
```

If the branch doesn't exist, stop and report the error. If `git status`
prints anything, stop. Show the list and ask the user to commit or stash
the changes. A checkout carries them onto the milestone branch.

```bash
git checkout milestone/$ARGUMENTS
git pull --ff-only origin milestone/$ARGUMENTS
```

If the checkout or the pull fails, stop and report the error.

**Do not trust that `/flow:finish-milestone` actually finished** — verify
against repo state rather than assume the handoff was clean (same principle
`/flow:execute-plan` applies to a plan file's checkboxes):

- Release notes have no remaining `WIP:` markers:

  ```bash
  flow-check-wip-markers $ARGUMENTS
  ```

  Exit 1 means one or more markers remain (see stdout). Stop. Tell the user
  `/flow:finish-milestone` Step 6 hasn't actually finished — type
  `/flow:finish-milestone $ARGUMENTS` to run it again before continuing.
  Exit 2 means the release notes file is missing entirely — same stop, same
  instruction. Exit 10 means the `release_notes` key is absent. Add "WIP
  marker check: no `release_notes` key in .claude/project.md" to the skipped
  list and go on.

- **The verification and review steps (3.7, 9.5, 9.7, 9.8, 9.9) actually
  ran** — clean release notes only prove Step 6 finished; they say nothing
  about whether review happened, since those steps run later. An
  interrupted `/flow:finish-milestone` run (crash, cancelled session,
  context limit) could otherwise leave the release notes clean with zero
  local review having occurred. Check for the completion marker:

  ```bash
  cat "$RELEASES/$ARGUMENTS-review.done"
  ```

  If missing, or if any of the five step lines reads anything other than
  `clean`, `findings-fixed`, `ran-clean`, or `not-applicable` (e.g. it's
  absent entirely, or a line for one of the five steps is missing), stop.
  Tell the user:
  "`/flow:finish-milestone` doesn't show as having completed its review
  steps — type `/flow:finish-milestone $ARGUMENTS` to run it again before
  opening a PR." Do not proceed on the assumption that review "probably"
  happened — this check exists specifically for the case where it didn't.

- **The marker covers the branch as it is now.** Its `sha:` line records the
  last reviewed tip. `/flow:finish-milestone` Step 10 writes it, and Step 4
  here moves it to each fix commit that Step 4 verified and pushed. A commit
  after that tip had no review:

  ```bash
  grep '^sha: ' "$RELEASES/$ARGUMENTS-review.done"
  git rev-parse origin/milestone/$ARGUMENTS
  git rev-list --count origin/milestone/$ARGUMENTS..milestone/$ARGUMENTS
  ```

  The `sha:` value must equal the `origin` tip, and the count must be `0`
  (`gh pr create --head` in Step 3 does not push, so a local-only commit is
  not in the PR). If the `sha:` line is missing or differs, or the count is
  not `0`, stop. Show the commits after the marker
  (`git log --oneline <sha>..milestone/$ARGUMENTS`). Tell the user to type
  `/flow:finish-milestone $ARGUMENTS`. It skips the review steps whose
  results still match the tip, and reviews the new commits.

### Step 2: Re-derive merged-PR list, diff, and milestone-check status

Re-run these fresh rather than assume anything from an earlier
`/flow:finish-milestone` run is still current — the branch may have changed
since:

```bash
gh pr list --base milestone/$ARGUMENTS --state merged --json number,title,url
git log main..milestone/$ARGUMENTS --oneline
git diff --stat main..milestone/$ARGUMENTS
```

Run the milestone checks again. If the `milestone_checks` key is absent, add
"milestone_checks: no key in .claude/project.md" to the skipped list and go
to Step 3. Otherwise, run the value of `milestone_checks` as a shell command
from the repo root.

- **Exit 0** — the checks pass. Proceed to Step 3.
- **Non-zero exit** — stop. Show the output. A fix is a new commit, and
  Step 1 accepts only reviewed commits. End with plain text: fix each
  failure as a commit on `milestone/$ARGUMENTS`. Then run `/clear` and type
  `/flow:finish-milestone $ARGUMENTS`. It reviews the new commit and skips
  the steps whose results still match.

### Step 3: Create the PR targeting main, or reuse the open one

Look for an open milestone PR from an earlier run first:

```bash
gh pr list --base main --head milestone/$ARGUMENTS --state open \
  --json number,url,body
```

- **One PR** — reuse it. Record its number and URL. Build the body below
  from Step 2's data. If the "Issues Resolved" or "Accepted Risks" section
  differs from the PR's body, replace the body:
  `gh pr edit <pr-number> --body-file <file> --repo $REPO`.
  Then go to Step 4.
- **More than one PR** — stop and ask the user which PR to use.
- **No PR** — create it:

```bash
gh pr create \
  --base main \
  --head milestone/$ARGUMENTS \
  --title "$ARGUMENTS — <milestone name>" \
  --body "$(cat <<'EOF'
## Summary

<1-2 sentence description of the milestone's purpose>

## Issues Resolved

<One line for each issue that a merged PR resolved>

Closes #NNN — Issue title (PR #NN)
Closes #NNN — Issue title (PR #NN)

## Release Notes

See `<NOTES_PATH>` for complete release notes.

<!-- Include this section ONLY if RELEASES/$ARGUMENTS-accepted-risks.md
     exists (written by /flow:finish-milestone Step 9.8). Copy its lines
     unchanged. Each line has the form below. <follow-up> is #<N> or
     "no follow-up". -->

## Accepted Risks

- <finding> — <reason> (<follow-up>)

## Test Plan

- [ ] All issue PRs were reviewed and merged into milestone branch
- [ ] Milestone checks pass (`milestone_checks`, if the project has them)
- [ ] Verification passed on the merged tree (`verify`, if the project has
      it; `/flow:finish-milestone` Step 3.7)
- [ ] Manual verification of key user flows
- [ ] Security review completed (run before this PR was created)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Replace `<NOTES_PATH>` with the path from Step 0. If the `release_notes` key
is absent, leave out the "Release Notes" section.

**CRITICAL**: The PR body MUST include `Closes #NNN` for every issue that a
merged PR in Step 2's list resolved, and for no other issue. Individual
issue PRs target the milestone branch (not main), so their closing keywords
won't auto-close issues. Only this final PR merged into main triggers
auto-closure. An issue with no merged PR is not done. Do not write a
`Closes` line for it: the merge would close it. `/flow:finish-milestone`
Step 2 already removed such issues from the milestone.

Fill in actual data from Step 2.

### Step 4: Verify CI milestone review posted, with zero unresolved findings

`claude-code-review.yml` is *expected* to run the same milestone-level
analysis `/flow:finish-milestone` Step 9.8 already ran locally, against
`main`, and post it as a PR comment — but a job `conclusion: success` is
never proof that happened (webhook throttle, the action's own
workflow-file-match guard, or turn exhaustion can each complete a job while
posting nothing). Verify the comment itself, and its content, in one call:

Run it with the Bash tool `timeout: 600000`:

```bash
flow-verify-ci-review <pr-number> 30 300 --trigger=label \
  --include-important --check-skip-tag
```

(30s/5min: milestone reviews run longer than per-push reviews.)

- **Exit 0** — comment confirmed, zero unresolved Blocking/Important
  findings. Note "posted normally" in the Step 5 summary and proceed.
- **Exit 1** — could not verify (`gh` auth/network/rate-limit). Do not
  treat it as "no review." Stop and report the error. Tell the user to fix
  the cause (for example, `gh auth login`), then type
  `/flow:review-milestone $ARGUMENTS`. Step 3 reuses the open PR.
- **Exit 2** — comment confirmed, but an unresolved Blocking or Important
  finding remains (see the review comment for the findings). Fix it here:
  `/flow:release-milestone` does not fix findings. For each fix:

  1. Commit it on the milestone branch.
  2. If the `verify` key is present, run its value as a shell command (run
     with the Bash tool `timeout: 600000`). A non-zero exit blocks the push.
     If a component could not run, fix the environment and run it again.
     Do not push until it exits 0. If the `verify` key is absent, add
     "verify: no key in .claude/project.md" to the skipped list.
  3. Push it: `git push origin milestone/$ARGUMENTS`.
  4. Move the marker's `sha:` line to the pushed tip. The fix went through
     this loop (verification, then a new CI review), so Step 1 must accept
     it when the command runs again:

     ```bash
     f="$RELEASES/$ARGUMENTS-review.done"
     { echo "sha: $(git rev-parse origin/milestone/$ARGUMENTS)"; grep -v '^sha: ' "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
     ```

     Only this step moves the `sha:` line. A commit that did not go through
     steps 1–3 here still needs `/flow:finish-milestone $ARGUMENTS`.

  A push does not start a new review. Neither review job runs on a
  `synchronize` event for a `milestone/*` → `main` PR. Start one with a
  fresh `deep-review` label. Remove it first, so the add fires a new
  `labeled` event. If the PR does not have the label, skip the remove:

  ```bash
  gh pr edit <pr-number> --remove-label deep-review --repo $REPO
  gh pr edit <pr-number> --add-label deep-review --repo $REPO
  ```

  Wait for the `milestone-review` check to finish
  (`gh pr checks <pr-number> --watch`, run with the Bash tool
  `timeout: 600000`), then run this script again. The script accepts only
  a review comment that has a verdict for the head commit. It
  waits for that comment, and it ignores the old one. Repeat until it
  exits 0. If a finding needs user judgment or access only they
  have (e.g. a production-host check), use AskUserQuestion — "defer to a
  tracked follow-up" is acceptable, but must be an explicit recorded choice,
  never a silent skip.
- **Exit 3** — PR title carries `[skip-review]`; no comment is the correct,
  by-design outcome. Report "review intentionally skipped per title tag"
  and proceed to Step 5.
- **Exit 4** — no review comment for the head commit, even after the
  script's one recovery attempt. Show the script's stderr. Then check
  whether the PR changes the review workflow itself:

  ```bash
  gh api "repos/$REPO/pulls/<pr-number>/files" --paginate \
    --jq '.[].filename' | grep -Fx .github/workflows/claude-code-review.yml
  ```

  - **A line prints** — the action's workflow-file guard skips the review
    until this change is on `main`. No new run can post one. Ask with
    AskUserQuestion: `Proceed without the CI review` or `Stop`. On
    `Proceed without the CI review`, go to Step 5. Its CI review line
    records this choice. On `Stop`, end with plain text: when ready, type
    `/flow:review-milestone $ARGUMENTS`.
  - **Nothing prints** — stop. Show the latest `milestone-review` run:
    `gh run list --workflow claude-code-review.yml --branch milestone/$ARGUMENTS --limit 3`.
    End with plain text: wait until that run finishes, or fix the cause
    that its log shows. Then type `/flow:review-milestone $ARGUMENTS`. Step
    3 reuses the open PR, and Step 4 tries the recovery again.

**All CI checks must be green, not only the review.** Run
`gh pr checks <pr-number>`. A check skipped by design is fine.

- **A required check is pending** — wait for it:
  `gh pr checks <pr-number> --watch`, run with the Bash tool
  `timeout: 600000`. Then run `gh pr checks <pr-number>` again.
- **A check failed** — read its log:
  `gh run view <run-id> --repo $REPO --log-failed`.
  - The failure needs a code change: fix it with items 1–4 of the exit 2
    loop above. Then start a new review with the `deep-review` label, as
    that loop does. Run `flow-verify-ci-review` again: the fix commit is a
    new head, and it needs its own review.
  - The failure is not in the code (a runner or network error): run the
    failed jobs again with
    `gh run rerun <run-id> --failed --repo $REPO`.
    Then wait for the check as for a pending check.

  Do not go to Step 5 until every check is green or skipped by design.

**The bar for calling this command complete:** the milestone branch, as it
sits on `main`'s target commit right now, needs zero further code changes
before `/flow:release-milestone` runs — that command merges, tags, and
publishes; it is not a place to discover or fix problems.

### Step 5: Output summary

- The PR number and URL
- List of merged issue PRs included
- Milestone checks status (passed, or skipped)
- CI milestone review status (from Step 4): "posted normally" / "no run was
  triggered — re-triggered via deep-review label, now posted" / "no review
  — self-referential workflow-file change, user chose to proceed without
  the CI review" / etc. — never omit this line
- Note as plain text (informational, not a runnable choice): "To re-run the
  deep review later, label the PR `deep-review` or comment `@claude
  deep-review`"
- Skipped steps, as this list:

  ```markdown
  Skipped steps:
  - <step>: <reason>, for example "verify: no key in .claude/project.md"
  ```

  Write "Skipped steps: none" when no step skipped.
- Then use AskUserQuestion for the actual next step, since
  `/flow:release-milestone` is runnable right now — it merges the PR itself
  (that's its Step 6), it does not wait for a human to merge on GitHub
  first. Both commands declare `model: sonnet`, so the Skill tool can start
  it (the `flow:workflow` skill, `SKILL.md`, "Hand-offs between commands"):
  - Question: "Milestone PR ready. What next?"
  - Options: `Run /flow:release-milestone $ARGUMENTS` (recommended — merges
    the PR, tags, and publishes the release), `Ask more questions / review
    the PR myself first`
  - If the user picks `/flow:release-milestone`, invoke it immediately via
    the Skill tool. If they pick the discuss option, drop into normal
    conversation and don't re-offer until they ask what's next.
