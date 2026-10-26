---
description: Gate a milestone branch — verify it, review it, and bring documentation up to date before /review-milestone opens a PR
model: claude-fable-5-1
---

# Finish Milestone

Keep output brief — terse status lines, no preamble, no restating of steps.

Verify a milestone branch is complete, run every review pass, and bring
release notes up to date. This command ends when the branch is fully vetted
— no PR exists yet. `/flow:review-milestone` picks up from here: it opens
the PR, verifies CI review posted, and confirms CI is green.

The method is in the `flow:workflow` skill, `references/ship.md`, "Finish
the milestone".

## Arguments

- `$ARGUMENTS` — the milestone version number (e.g., `v2.17.0`)

## Important

- Push only `milestone/$ARGUMENTS`, only to `origin`, and only in Step 10.
  Do not create a PR — that's `/flow:review-milestone`'s job
- If release notes still have WIP markers, flag this prominently before
  handing off
- Deployment procedure content belongs in the project's deploy procedure
  (`deploy` key), not in the release notes file — that file is a
  user-/admin-facing changelog plus a one-sentence-per-issue index

## Step 0: Project facts

1. Run `flow-project-check`. If it fails, show its output. Tell the user to
   fix `.claude/project.md` or run `/flow:setup`. Stop.
2. Read each fact that this command needs with `flow-project-fact <key>`:
   `plans`, `release_notes`, `verify`, `milestone_checks`, `ledger`.
3. If `plans` is absent, stop. Tell the user: "This command writes the
   review marker in the `plans` folder. Add the `plans` key to
   `.claude/project.md`."
4. Call `<plans>/releases` the `RELEASES` folder. Replace `{version}` in the
   `release_notes` value with `$ARGUMENTS`. Call the result `NOTES_PATH`. If
   `release_notes` is absent, add each step that needs `NOTES_PATH` to the
   skipped list.
5. Run `flow-repo`. Keep the result as `REPO`. Use `$REPO` in each command
   below.
6. If another key is absent, add its step to the skipped list when you reach
   that step.

## Running the command again

The user can type `/flow:finish-milestone $ARGUMENTS` again after a run
stops or after the branch changes. The new run starts at Step 0 and skips a
step when that step's result already exists for the current branch tip. The
files are in `RELEASES`:

- Steps 3.7, 9.5, 9.7, 9.8 and 9.9 skip when the `sha:` line of
  `$ARGUMENTS-review.prev` (Step 0a makes it) equals
  `git rev-parse milestone/$ARGUMENTS` at the start of the step. Step 10
  copies each skipped step's line from that file. A new commit changes the
  tip, so these steps run again.
- Step 6.5 skips when `$ARGUMENTS-retro.md` exists.
- All other steps run again. They read the current state.

When a step skips, set its task to `completed` and report "skipped — result
exists for `<short sha>`".

## Workflow

### Step 0a: Initialize TaskList

Before any other action, create one TaskCreate task per step below:

- Step 1. Verify the milestone branch exists
- Step 2. Check for open issues still in the milestone
- Step 3. Switch to milestone branch and ensure up to date
- Step 3.5. Run the milestone checks
- Step 3.6. Check for leftover plan files
- Step 3.7. Run the verification command on the merged tree
- Step 4. Gather all merged PRs targeting the milestone branch
- Step 5. Get the full diff against main
- Step 5.5. Verify milestone scope vs. release notes
- Step 6. Finalize release notes
- Step 6.5. Release retrospective — three questions
- Step 9.5. Cross-PR security check
- Step 9.7. Local multi-agent review
- Step 9.8. Local milestone-level deep review — mirrors CI, runs pre-PR
- Step 9.9. Fresh-checkout smoke test (if build/install steps changed)
- Step 10. Push the milestone branch, output summary, and hand off to /flow:review-milestone

Set each task to `in_progress` when you begin it and `completed` on success.

Then move the completion marker of an earlier run out of the way.
`/flow:review-milestone` trusts only `$ARGUMENTS-review.done`, so a run that
stops before Step 10 must not leave the old one in place. The `.prev` copy
keeps the earlier results for the skip rules in "Running the command
again":

```bash
if [ -f "$RELEASES/$ARGUMENTS-review.done" ]; then
  mv "$RELEASES/$ARGUMENTS-review.done" "$RELEASES/$ARGUMENTS-review.prev"
fi
```

### Step 1: Verify the milestone branch exists

- Check `git branch -a | grep "milestone/$ARGUMENTS"`
- If not found, stop. Tell the user that `milestone/$ARGUMENTS` does not
  exist. If the version is wrong, type `/flow:finish-milestone <version>`
  with the correct version. If the milestone has no branch yet, type
  `/flow:start-milestone $ARGUMENTS`.
- Get the GitHub milestone number. Find the open milestone whose title
  starts with the version:

  ```bash
  gh api "repos/$REPO/milestones?state=open&per_page=100" \
    --jq '.[] | select(.title | test("^$ARGUMENTS([: ]|$)")) | .number'
  ```

  Exactly one number → record it as `MILESTONE_NUM`. Zero or more than one →
  stop and ask the user. Steps 2 and 5.5 use it.

### Step 2: Check for open issues still in the milestone

Use the direct API, not `gh issue list --milestone` (the `flow:workflow`
skill, `references/github.md`, "gh CLI gotchas"). Use `MILESTONE_NUM` from
Step 1:

```bash
gh api "repos/$REPO/issues?milestone=<MILESTONE_NUM>&state=open&per_page=100" \
  --paginate --jq '.[] | {number, title}'
```

- If open issues remain, warn user and list them. Ask, for each issue,
  whether to finish it first or leave it out of this release.
- If the user wants to finish any issue first, stop now. Do not remove
  anything yet: the next run asks again about each issue that is still
  open. End with plain text: for each issue to finish, run `/clear`, then
  type `/flow:start-issue <N>` and follow the per-issue commands through
  `/flow:finish-issue`. Then run `/clear` and type
  `/flow:finish-milestone $ARGUMENTS`.
- Otherwise, for each issue the user leaves out, remove its milestone, so
  `/flow:plan-milestone` sees it again as unplanned work:

  ```bash
  gh issue edit <N> --repo $REPO --remove-milestone
  ```

  After Step 3 checks out the milestone branch, remove the issue's `WIP:`
  entry from "Issues Resolved" in `NOTES_PATH`, and any changelog bullet for
  it. Commit the change. If `release_notes` is absent, skip this edit.

### Step 3: Switch to milestone branch and ensure up to date

Check for uncommitted changes first:

```bash
git status --porcelain
```

If it prints anything, stop. Show the list and ask the user to commit or
stash the changes. A checkout carries them onto the milestone branch.

```bash
git checkout milestone/$ARGUMENTS
git pull --ff-only origin milestone/$ARGUMENTS
```

If the checkout or the pull fails, stop and report the error.

### Step 3.5: Run the milestone checks

If the `milestone_checks` key is absent, add "milestone_checks: no key in
.claude/project.md" to the skipped list. Go to Step 3.6.

Run the value of `milestone_checks` as a shell command from the repo root.

- **Exit 0** — the checks pass. Go to Step 3.6.
- **Non-zero exit** — stop. Show the output. Do not go on. End with plain
  text: fix each failure as a commit on the milestone branch, then type
  `/flow:finish-milestone $ARGUMENTS`. If a failure is acceptable, the user
  must change the check in the project. This command does not accept a
  failed check.

### Step 3.6: Check for leftover plan files

Each issue's `/flow:finish-issue` run deletes its plan file in
`<plans>/issues/` as part of closing out that issue. A file still present
here means that step was skipped — most likely an issue whose PR was merged
some other way (bypassing `/flow:finish-issue`), or an interrupted run.

The `plans` folder is git-ignored, so these files never reach the PR — but
they do accumulate silently on disk, and nothing else is positioned to catch
them. List them directly:

```bash
find "$(flow-project-fact plans)" -maxdepth 2 \( -name 'issue-*.md' \
  -o -path '*/issues/issue-*.md' \)
```

**If any files are found:** present them to the user and ask whether to
delete them now (if the corresponding issue is confirmed closed and merged)
or investigate first (if it's unclear whether that issue's work actually
completed). Do not silently delete — a plan file could also mean genuinely
unfinished work that never went through `/flow:finish-issue` at all.

**If none found:** proceed silently — this is the expected state.

### Step 3.7: Run the verification command on the merged tree

Skip this step when the `sha:` line of `$ARGUMENTS-review.prev` equals the
branch tip (see "Running the command again").

If the `verify` key is absent, add "verify: no key in .claude/project.md"
to the skipped list. Go to Step 4.

Each issue ran its own tests on its own branch. This is the one full run on
the merged milestone tree. Run the value of `verify` as a shell command from
the repo root. Run it with the Bash tool `timeout: 600000`.

- **Exit 0** — passed. Proceed to Step 4.
- **Non-zero exit** — blocking. Show the output. If a component could not
  run (for example, a stopped service), that is not a clean result: fix the
  environment and run the command again. If a component failed, fix the
  failure as a commit on the milestone branch, then run the command again.
  Do not continue until it exits 0.

If a later step commits a code change (not only docs), Step 10 runs the
command again.

### Step 4: Gather all merged PRs targeting the milestone branch

```bash
gh pr list --base milestone/$ARGUMENTS --state merged --json number,title,url
```

### Step 5: Get the full diff against main

```bash
git log main..milestone/$ARGUMENTS --oneline
git diff --stat main..milestone/$ARGUMENTS
```

### Step 5.5: Verify milestone scope vs. release notes

Issues get moved in and out of a milestone over its lifetime — rescoped to a
different milestone, split off, superseded, or consolidated after their PR
already merged and their release-notes entry was already written. The
release notes reflect scope *at the time each issue was worked*, which can
silently drift from the milestone's *current* actual membership by the time
the milestone finishes. Catch this before finalizing, not after — a release
note that credits work to the wrong milestone (or omits real work) is wrong
in a way none of the later review steps are positioned to catch, since they
all take the release notes' existing content as ground truth.

1. Compare the milestone's current membership (all states) with the
   "Issues Resolved" entries. Use `MILESTONE_NUM` from Step 1:

   ```bash
   flow-check-milestone-scope-drift $ARGUMENTS <MILESTONE_NUM>
   ```

   - **Exit 0** — scope matches. Go to the last paragraph of this step.
   - **Exit 1** — the script printed one or more mismatched issues, each
     with what is wrong. Investigate each one (item 2). Exit 1 with no
     issue lines printed counts as exit 2.
   - **Exit 2** — can't verify: no release-notes file, no "Issues Resolved"
     entries, a milestone with no issues (usually a wrong milestone
     number), or a `gh` or tool failure. This is not "scope matches". Stop
     and fix the cause, then run the script again.
   - **Exit 10** — no `release_notes` key. Add "scope drift check: no
     `release_notes` key in .claude/project.md" to the skipped list. Go to
     Step 6.5.

2. Investigate every mismatch:

   - **"moved out of milestone since release notes were written"** — this issue
     was moved elsewhere after its entry was written, or Step 2 left it out
     of this release. Confirm where it lives now:

     ```bash
     gh issue view <N> --repo $REPO --json milestone,state
     ```

     If it genuinely moved to a different milestone, or has no milestone,
     remove its "Issues Resolved" entry and any associated changelog bullet (New
     Features/Improvements/Bug Fixes) — that work no longer ships in this
     release. Also re-check whether the release's headline "Type" line and
     summary still make sense without it (a moved-out issue can invalidate
     the release's stated theme, not just one bullet). An entry marked
     "Carried from …" (work carried from a different milestone) also shows
     here. It is intended. Keep it.

   - **"still has WIP prefix in release notes"** — the issue has an entry.
     Do not draft a new one. Step 6 checks each `WIP:` prefix.

   - **"added to milestone, missing from release notes"** — if the issue is
     still open, Step 2 already covers it. If it is closed, it is a real
     gap. Check why it has no entry:

     ```bash
     gh issue view <N> --repo $REPO --json state,stateReason,comments \
       --jq '{state, stateReason, comments: [.comments[].body]}'
     ```

     - Comment says **"Consolidated into #X"**: expected, no separate entry
       needed — confirm #X's existing entry actually covers this issue's
       scope, then move on.
     - Comment says **"Superseded by #X"**: check #X's *current* milestone.
       If #X is in this same milestone, its entry already covers this issue
       — no action needed. **If #X is in a different milestone (or its work
       was never actually merged into this milestone branch — verify with
       `git log milestone/$ARGUMENTS --oneline --grep="<X or a keyword>"`),
       this issue is claiming credit for work that doesn't actually ship
       here either.** This is the same drift as the first bullet, one hop
       removed. Do not guess how to resolve it — present it to the user with
       the full chain (this issue → superseded by #X → #X's actual
       milestone) and ask: move this issue to match #X's milestone, list it
       here with a "no code shipped" note, or something else.
     - No such comment: genuine gap. Draft an accurate "Issues Resolved"
       entry (and a changelog bullet, if it represents real shipped
       behavior rather than a purely operational/verification action — e.g.
       "confirmed working after a config redeploy" belongs in Issues
       Resolved but may not need its own user-facing changelog bullet) from
       the issue's title, body, and closing comment.

3. **Present every discrepancy found to the user before editing anything.**
   Unambiguous cases (confirmed moved to another milestone; confirmed
   consolidated with an entry already present) can be applied directly and
   just noted in the summary. Ambiguous cases (the superseded-elsewhere
   pattern above) require the user's explicit decision — do not proceed on
   your own judgment.

4. Apply the agreed changes to `NOTES_PATH` and commit them. If a GitHub
   milestone reassignment was part of the resolution (e.g. moving an issue
   to match where its superseding issue actually lives):

   ```bash
   gh issue edit <N> --repo $REPO --milestone "<target milestone title>"
   ```

   Run the script again. Each line it still prints must be one the user
   confirmed as intended.

If no discrepancies are found, note that in the summary and continue — this
step doesn't need to slow down a milestone where nothing moved.

### Step 6: Finalize release notes at `NOTES_PATH`

If the `release_notes` key is absent, add "release notes: no `release_notes`
key in .claude/project.md" to the skipped list. Go to Step 6.5.

- Check for any remaining `WIP:` prefixes in the "Issues Resolved" section:

  ```bash
  flow-check-wip-markers $ARGUMENTS
  ```

  Exit 0 means none remain. Exit 1 prints each remaining marker (see
  stdout). Exit 2 means the release notes file itself is missing — fix that
  first.

  Each remaining marker means an issue's `/flow:finish-issue` run never
  stripped it — either that issue's PR never actually merged (contradicts
  Step 2's "no open issues remain" check, so investigate that discrepancy
  first) or its `/flow:finish-issue` run skipped the strip step for some
  other reason. Do not strip a remaining `WIP:` prefix yourself as a
  shortcut — confirm the issue is genuinely closed and merged (cross-check
  against Step 4's merged-PR list) before removing it, since this prefix is
  the one signal that distinguishes "planned" from "actually shipped" in
  this document.
- Use the `flow:technical-documentation-writer` agent to finalize:
  - Fill in any remaining template placeholders
  - Apply the release notes template's "Be brief" rule, if it has one, to
    the whole file. The file is the GitHub release body. Cut the summary to
    at most 2 sentences. Merge entries until each issue has at most one
    entry in the user-facing or admin-facing changes. Cut each entry to one
    sentence of at most 20 words. Delete entries for changes no one can see.
    Full detail lives in the issue/PR itself
  - Scope accuracy (issue membership vs. milestone) was already verified in
    Step 5.5 — this pass is about content completeness/wording, not re-doing
    that cross-check
  - Deployment steps do **not** belong in this file. They belong in the
    project's deploy procedure (`deploy` key)
- Commit the finalized release notes if changes were made (or amend the
  Step 5.5 commit, to keep history clean — nothing is pushed before
  Step 10)

### Step 6.5: Release retrospective — three questions

Skip this step when `RELEASES/$ARGUMENTS-retro.md` exists.

Five minutes. One line each is enough. The answers go to the git-ignored
`RELEASES/$ARGUMENTS-retro.md`, not to the release notes (the `flow:workflow`
skill, `references/ship.md`, "Retrospective").

Ask the user, one at a time:

1. > "What did we ship in this release that nobody needed?"

   Be specific — name the issue.

2. > "What did we learn about this theme's audience?"

3. > "What signal arrived during this milestone that we ignored — and was that
   > right?"

Write the answers to `RELEASES/$ARGUMENTS-retro.md`. The next
`/flow:plan-milestone` Step 1 reads that file before it chooses the theme,
so the theme is chosen knowing what the last one over-built.
`/flow:start-milestone` Step 4.4 reads it too, but only for a milestone that
is not sealed.

### Step 9.5: Cross-PR Security Integration Check

Skip this step when the `sha:` line of `$ARGUMENTS-review.prev` equals the
branch tip (see "Running the command again").

By the time this step runs, every individual issue PR has already passed
`flow:security-reviewer` in `/flow:execute-plan` and the project's CI
checks. Do **not** re-run a full OWASP pass over already-reviewed files.

Instead, run a targeted cross-PR integration check. Get the full diff:

```bash
git diff main...milestone/$ARGUMENTS
```

Launch the `flow:security-reviewer` agent with this scoped prompt:
> "Review only for cross-PR security interactions introduced by combining
> these changes. Focus on: (1) new code paths where output from one changed
> file flows into input handling in another changed file; (2) changes to
> shared auth, session, or CSRF middleware; (3) any file touched by 3+ PRs
> that may have accumulated risk across changes. Skip file-level OWASP
> checks — those were done per-issue. Report only findings that could not
> have been caught by reviewing each PR in isolation."

- If **Critical or High** cross-integration findings are found, do not go
  to Step 9.7. Show each finding. Fix each one in this session as a commit
  on the milestone branch, after the user approves the fix. Then do this
  check again on the new diff. If the user wants to fix them outside this
  session, stop. End with plain text: commit the fixes on the milestone
  branch, then type `/flow:finish-milestone $ARGUMENTS`. It skips the steps
  whose results exist for the current tip (see "Running the command
  again").
- If there are Medium or Low findings, handle each one as "Medium and Low
  findings" below says. Then go to Step 9.7.
- If there are no findings, go to Step 9.7.

**Medium and Low findings.** Do not only note them in the summary. Send
each one to one place:

- **Cleanup ledger** — a finding that changes no behaviour (dead code,
  duplication, naming, comments, types, lint noise). If the `ledger` key is
  present, add one line to the ledger file under the heading for its file,
  as the ledger's own rules say (the `flow:workflow` skill,
  `references/plans-and-ledger.md`, "Cleanup ledger"). End the line with
  `(found in /flow:finish-milestone $ARGUMENTS)`. Commit the edit on the
  milestone branch. If the `ledger` key is absent, add "ledger: no key in
  .claude/project.md" to the skipped list. Send the finding to a new GitHub
  issue instead.
- **New GitHub issue** — a defect. Follow `/flow:found`'s "Defer" steps
  (`bug:` title, labels `bug,triage,signal:discovered`, no milestone). In
  the body, write `Found by /flow:finish-milestone $ARGUMENTS.` in place of
  the `#CURRENT_ISSUE` line.

Add each finding to the resolved-findings list that Step 9.8 receives:
`file:line`, one line of description, and `ledger` or `issue #<N>`.

### Step 9.7: Local multi-agent review (before opening the PR)

Skip this step when the `sha:` line of `$ARGUMENTS-review.prev` equals the
branch tip (see "Running the command again").

Launch the review agents below on the milestone diff against `main`. Do not
run the `/flow:review-pr` command (the `flow:workflow` skill, `SKILL.md`,
"Command order"). Scope the agents to the file types changed — don't run all
agents unconditionally.

Determine which agents apply based on `git diff --name-only main...milestone/$ARGUMENTS`:

| Changed file types | Agents to run |
| --- | --- |
| Source code files | `flow:code-reviewer`, `flow:silent-failure-hunter` |
| Source code with forms, queries, or input handling | + `flow:security-reviewer` (file-level review only — Step 9.5 already covered cross-PR interaction effects; don't re-derive those here) |
| New classes or types | + `flow:type-design-analyzer` |
| Test files changed | `flow:pr-test-analyzer` |
| Docs/comments changed | `flow:comment-analyzer` + independent fact-check (see `/flow:review-pr` Step 4.5 — fresh, context-free agent re-derives each factual claim from source rather than trusting the diff) |

Launch only the applicable agents in parallel, skipping any type not present in the diff.

Focus areas at milestone level:

- Cross-issue integration (did two PRs introduce contradictions?)
- Release-notes accuracy vs. the merged PR list
- Aggregated security surface

If Critical or Important issues surface, do not go to Step 9.8. Fix each
one in this session as a commit on the milestone branch, after the user
approves the fix. Then launch the same agents again on the new diff. If
the user wants to fix them outside this session, stop. End with plain
text: commit the fixes on the milestone branch, then type
`/flow:finish-milestone $ARGUMENTS`. It skips the steps whose results exist
for the current tip (see "Running the command again").

Handle each lower-severity finding (a Suggestion, Medium, or Low) as
Step 9.5 "Medium and Low findings" says.

Once the local review is clean, add what Step 9.7 found to the
resolved-findings list that Step 9.5 started: `file:line`, one line of
description, and `fixed`, `ledger`, or `issue #<N>`. Write "none" when
Steps 9.5 and 9.7 found nothing. Step 9.8 needs this list so that it does
not report the same items as new findings.

Proceed to Step 9.8.

### Step 9.8: Local milestone-level deep review (mirrors CI, runs before the PR exists)

Skip this step when the `sha:` line of `$ARGUMENTS-review.prev` equals the
branch tip (see "Running the command again").

Step 9.7 reviews individual files by type. This step instead runs the same
**aggregate, milestone-level** analysis that the CI `milestone-review` job
performs — but locally, before the PR is even created.

Build the inputs (the merged PR list from Step 4 and the diff from Step 5 are
already available):

```bash
gh pr list --base milestone/$ARGUMENTS --state merged --limit 100 \
  --json number,title,mergedAt,author \
  --jq '.[] | "#\(.number) \(.title) (by @\(.author.login))"'
git diff main...milestone/$ARGUMENTS
```

Delete `RELEASES/$ARGUMENTS-accepted-risks.md` if it exists. Its findings
belong to an earlier branch tip, and this run decides each one again.

Launch a single agent via the Agent tool with
`subagent_type: "flow:senior-architect"` and `model: "fable"` (matching the
CI job's tier — once per milestone, not per push). Provide it with:

- The merged PR list (from the command above)
- The full diff `main...milestone/$ARGUMENTS`
- The finalized release notes at `NOTES_PATH` (if the `release_notes` key
  is present)
- The resolved-findings list from Steps 9.5 and 9.7 (or "none"), with the
  instruction not to
  re-report those as new findings — this step catches only what per-file
  review can't (cross-PR interactions, aggregate surface)

Ask it to perform the same five checks the CI job does:

1. **Release notes accuracy** — compare the merged PR list against the release
   notes. Flag missing, duplicated, or mis-categorized entries.
2. **Architecture drift** — is the aggregated shape coherent with the
   project's CLAUDE.md? Any cross-cutting changes that its docs must
   describe?
3. **Cross-issue integration** — interactions between merged PRs: shared
   types, shared DB schema, shared JS globals, API contract drift between
   endpoints touched by different PRs.
4. **Security surface of the aggregate** — does the *sum* introduce a new
   vector that no single PR would have shown in isolation?
5. **Deployment readiness** — any new env vars, migrations, feature flags, or
   pre-deploy steps missing from the release notes or from the project's
   deploy procedure (`deploy` key)?

**This step blocks on any finding, not just Critical/High.** Present every
finding to the user regardless of severity. For each one: **fix it** (apply
the fix, launch this step's agent again on the corrected diff), or **user
explicitly accepts the risk**. No PR exists yet, so record each accepted
finding as one line in `RELEASES/$ARGUMENTS-accepted-risks.md`, in exactly
this form:

```text
- <finding> — <reason> (<follow-up>)
```

`<follow-up>` is the follow-up issue as `#<N>`, or `no follow-up`.
`/flow:review-milestone` Step 3 copies each line unchanged into the PR
body's "Accepted Risks" section. Do not proceed to Step 9.9 until every
finding is resolved or explicitly accepted — the CI job
(`/flow:review-milestone` Step 4) is a backstop/audit trail, not a
substitute decision point.

### Step 9.9: Fresh-checkout smoke test (only when build/install steps changed)

Skip this step when the `sha:` line of `$ARGUMENTS-review.prev` equals the
branch tip (see "Running the command again").

Every review above reads diffs and file contents. None *executes* anything
against a truly clean checkout. A build bug can hide from every diff review,
because existing checkouts already have the generated files on disk.

**Run this step whenever the milestone touched**: build or install tooling,
dependency manifests, the ignore file (new ignored generated-output paths),
or deploy-hook logic. Skip it for milestones with no such change — it exists
for exactly that class of bug, not as a general smoke test.

**Procedure:**

Find the project's install and build commands in its CLAUDE.md or in the
procedure that the `deploy` key names. If you find none, ask the user for
the commands. Do not guess them.

Use a scratch worktree, not your working checkout. It must show what a
fresh clone or deploy sees, with nothing left over on disk. Run from the
repo root. `--detach` is necessary: Step 3 checked out
`milestone/$ARGUMENTS` here, and git does not check out one branch in two
worktrees. An earlier run can leave a worktree at the path, so remove it
first:

```bash
git worktree prune
if [ -e /tmp/milestone-smoke-$ARGUMENTS ]; then
  git worktree remove --force /tmp/milestone-smoke-$ARGUMENTS
fi
git worktree add --detach /tmp/milestone-smoke-$ARGUMENTS milestone/$ARGUMENTS
```

If `git worktree remove` fails, the path is not a worktree. Stop and ask
the user before you delete it.

Run the install and build commands in a subshell, so the session stays in
the repo root:

```bash
(
  cd /tmp/milestone-smoke-$ARGUMENTS &&
  <install command> &&
  <build command>
)
```

Check the exit code AND the actual file listing of the build's expected
output under `/tmp/milestone-smoke-$ARGUMENTS`. A partial-then-crash run can
exit non-zero after it produced some files. A clean exit with missing output
is exactly the bug this step exists to catch.

If anything fails or produces incomplete output, fix it on the milestone
branch (same fix-then-re-verify loop as Step 9.8), then do this smoke test
again against the fixed commit. A fix commit moves the branch, so make the
worktree again with the commands above. Clean up the worktree when done.
`--force` removes it even when the build left files in it:

```bash
git worktree remove --force /tmp/milestone-smoke-$ARGUMENTS
```

Once clean, proceed to Step 10.

### Step 10: Push the milestone branch, output summary, and hand off to `/flow:review-milestone`

If any step after Step 3.7 committed a code change (not only docs), and the
`verify` key is present, run its value again (run with the Bash tool
`timeout: 600000`). Handle its exit codes as in Step 3.7.

Push the milestone branch. This command's commits (Steps 3.7–9.9) are local
until now, and `/flow:review-milestone` opens the PR with
`gh pr create --head`, which does not push:

```bash
git status --porcelain
git push origin milestone/$ARGUMENTS
git rev-list --count origin/milestone/$ARGUMENTS..milestone/$ARGUMENTS
```

The status must print nothing and the count must be `0`. If the push is
rejected or either check fails, stop and report the error. Do not write the
marker below.

Write a completion marker before summarizing — `/flow:review-milestone`
Step 1 checks for this rather than trusting that this command actually
reached Step 10 (a crashed, interrupted, or cancelled run could otherwise
leave clean release notes in place with zero review having happened, since
those are written earlier, in Step 6, before 9.5-9.9 run):

```bash
cat > "$RELEASES/$ARGUMENTS-review.done" <<EOF
sha: $(git rev-parse origin/milestone/$ARGUMENTS)
3.7: <ran-clean|not-applicable>
9.5: <clean|findings-fixed>
9.7: <clean|findings-fixed>
9.8: <clean|findings-fixed>
9.9: <ran-clean|not-applicable>
EOF
```

The `sha:` line is the pushed tip. `/flow:review-milestone` Step 1 checks
that it still equals `origin/milestone/$ARGUMENTS`.
`/flow:review-milestone` Step 4 moves it to each finding fix that it
verifies and pushes. Any other commit after this tip needs a new run of this
command. For a step that skipped under "Running the command again", copy its
line from `$ARGUMENTS-review.prev`. Then delete the old marker:

```bash
rm -f "$RELEASES/$ARGUMENTS-review.prev"
```

Use `not-applicable` for 3.7 only when the `verify` key is absent. Use
`not-applicable` for 9.9 only when Step 9.9's own trigger conditions
didn't apply to this milestone (no build/install/deploy tooling changed) —
not as a stand-in for skipping it when it should have run.

Then summarize:

- Milestone checks (Step 3.5): passed, or skipped
- Verification (Step 3.7): passed on the merged tree, or skipped
- Milestone-scope corrections from Step 5.5 (none found, or list issues added/removed/reassigned and why)
- Release notes status (finalized or needs attention)
- Review results (Steps 9.5, 9.7, 9.8, 9.9): clean, or each finding with its
  outcome (`fixed`, `ledger`, or `issue #<N>`)
- Accepted risks from Step 9.8 (none, or the path of the accepted-risks file)
- Push status: `milestone/$ARGUMENTS` is on `origin` at `<short sha>`
- Skipped steps, as this list:

  ```markdown
  Skipped steps:
  - <step>: <reason>, for example "milestone_checks: no key in .claude/project.md"
  ```

  Write "Skipped steps: none" when no step skipped.

End with plain text, not a menu. Tell the user to run `/clear` first, then
type `/flow:review-milestone $ARGUMENTS` (it opens the PR, or reuses the
open one, verifies that the CI review posted, and confirms green). This
context is very large, and `/flow:review-milestone` reads everything it
needs from the repo and the marker file. Do not start it through the Skill
tool: it declares `model: sonnet`, and a Skill-tool start runs it on this
command's model (the `flow:workflow` skill, `SKILL.md`, "Hand-offs between
commands").
