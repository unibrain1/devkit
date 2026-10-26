---
description: Merge a milestone PR into main, tag the release, and publish a GitHub release
model: sonnet
---

# Release Milestone

Keep output brief — terse status lines, no preamble, no restating of steps.

Merge a milestone PR into main, create an annotated tag, push to origin, and
publish a GitHub release. This command picks up where
`/flow:review-milestone` left off — after the milestone PR has been created,
CI-reviewed, and confirmed green.

The method is in the `flow:workflow` skill, `references/ship.md`, "Release
the milestone".

## Arguments

- `$ARGUMENTS` — (optional) the milestone version number (e.g., `v2.17.0`).
  If omitted, auto-detect from the open `milestone/*` → `main` PR.

## Important

- **Confirmation is required before Step 6.** Do not run the script without
  explicit user approval — it is the point of no return.
- This command assumes `/flow:finish-milestone` and `/flow:review-milestone`
  already ran.
- **Push only to `origin`.** `flow-release-milestone` pushes only to
  `origin`. This command never pushes to another remote.
- The release stays a **draft** until the user deploys — publishing it is a
  separate manual step (see Step 7).
- This command deletes the `milestone/*` branch after the merge (Step 6). A
  branch that stays keeps the milestone count up (the `flow:workflow` skill,
  `references/plan.md`, "Milestone limit").

## Step 0: Project facts

1. Run `flow-project-check`. If it fails, show its output. Tell the user to
   fix `.claude/project.md` or run `/flow:setup`. Stop.
2. Read each fact that this command needs with `flow-project-fact <key>`:
   `plans`, `release_notes`, `release_checks`, `deploy`.
3. If `plans` or `release_notes` is absent, stop. Tell the user:
   "`flow-release-milestone` needs the `plans` and `release_notes` keys. Add
   them to `.claude/project.md`."
4. Run `flow-repo`. Keep the result as `REPO`. Use `$REPO` in each command
   below.
5. If `release_checks` is absent, add "release_checks: no key in
   .claude/project.md" to the skipped list. If `deploy` is absent, ask the
   user for the deploy procedure when Step 7 needs it.

## Workflow

### Step 0a: Initialize TaskList

Create one tracking task per step using TaskCreate: find PR, verify
preconditions, check version, run release checks, confirm, run
`flow-release-milestone`, output summary. Set each to `in_progress`
then `completed`. On failure, leave it `in_progress` and surface the error.

### Step 1: Find the milestone PR

```bash
gh pr list --base main --state open \
  --json number,title,headRefName,url
```

- Filter for PRs where `headRefName` starts with `milestone/`
- If `$ARGUMENTS` is given, match against `milestone/$ARGUMENTS`
- Exactly one match → use it. Multiple → stop and ask the user.
- Zero matches → an earlier run may have merged the PR and then stopped.
  Without `$ARGUMENTS`, stop and ask the user for the version. With it,
  look for the merged PR:

  ```bash
  gh pr list --base main --head milestone/<version> --state merged \
    --json number,title,url
  ```

  One merged PR → this is a **resume after the merge**. Use that PR. In the
  milestone lookup below, use `state=all` instead of `state=open` (the
  milestone can already be closed). Then follow "Resume after the merge"
  below. No merged PR → stop and ask the user.
- Extract the version from the branch name (e.g., `milestone/v2.17.0` →
  `v2.17.0`) and the milestone number from the PR's milestone field.
- The milestone PR often has no milestone set (`milestone: null`). If so,
  find the number from the open milestone whose title starts with the
  version:

  ```bash
  gh api "repos/$REPO/milestones?state=open&per_page=100" \
    --jq '.[] | select(.title | test("^<version>([: ]|$)")) | .number'
  ```

  Exactly one number → use it. Zero or more than one → stop and ask the
  user. Steps 2 and 6 use this `<milestone-number>`.

Replace `{version}` in the `release_notes` value with the version. Call the
result `NOTES_PATH`.

#### Resume after the merge

The milestone branch is deleted and its release notes are gone, so the
checks in Steps 2–4 cannot run. The script checked them before the merge.

1. The working tree must be clean (`git status --porcelain` prints
   nothing). If it is not, stop and ask the user to commit or stash.
2. Skip Steps 2, 3 and 4.
3. In Step 5, show the PR, the version, and the steps that remain: tag the
   merge commit, push the tag, create the draft release, close the
   milestone. Ask the user to confirm.
4. Go to Step 6. The script skips the steps that are already done.

### Step 2: Verify preconditions

- The PR must be mergeable (no conflicts, checks passing).
- The working tree must be clean (`git status --porcelain`).
- Must be on `main` or the milestone branch. The scope-drift check below
  switches to the milestone branch.
- **No unresolved Blocking/Important review findings.** This command does
  not fix problems — it only merges/tags/publishes what
  `/flow:finish-milestone` and `/flow:review-milestone` already fully
  vetted.

```bash
gh pr view <number> --json mergeable,mergeStateStatus,statusCheckRollup
flow-check-blocking-findings <number> --include-important
```

- **Exit 0** — clean, proceed.
- **Exit 1** — an unresolved Blocking or Important finding exists. **Stop.**
  Do not proceed to Step 5 and do not fix it here. This command's next steps
  are irreversible merge/tag/publish actions. The PR is still open. Do not
  tell the user to fix the finding by hand and push: that skips the
  verification, and the review marker no longer matches the branch.
  End with plain text: run `/clear`, then type
  `/flow:review-milestone <version>`. Its Step 4 fixes each finding, runs the
  verification, pushes, moves the marker, and starts a new CI review.
  After it ends, type `/flow:release-milestone <version>`.
- **Exit 2** — can't verify: no review comment with a verdict for the head
  commit was found, or the `gh` call failed. Treat as "can't
  verify," not "clean." Stop and report the error. If no review comment
  posted, tell the user to type `/flow:review-milestone <version>`. It reuses
  the open PR and starts the CI review. For a `gh` failure, tell the user
  to fix the cause, then type `/flow:release-milestone <version>`.

This is a second, independent check on the same requirement
`/flow:review-milestone` Step 4 already enforces — it exists so a PR that
sat open a while, or reached this command by another path, still gets
caught.

**The milestone scope must still match the release notes.** The script
reads the release notes from the working tree, and only the milestone
branch has that file (`main` does not). Check out the milestone branch and
bring it up to date first, so the check reads the notes that will merge:

```bash
git checkout milestone/<version>
git pull --ff-only origin milestone/<version>
flow-check-milestone-scope-drift <version> <milestone-number>
```

If the checkout or the pull fails, stop and report the error. Do not run
the check against a stale or wrong checkout.

- **Exit 0** — scope matches, proceed.
- **Exit 1** — the script printed one or more mismatched issues. Do not go
  to Step 3 yet. Show each line to the user. Some mismatches are intended:
  - An issue carried from a different milestone ("Carried from …" in its
    release-notes entry) shows as "moved out of milestone".
  - An issue closed as consolidated into or superseded by another issue
    (see `/flow:finish-milestone` Step 5.5) shows as "added to milestone,
    missing from release notes".

  A "still has WIP prefix in release notes" line is never intended here.
  `/flow:review-milestone` Step 1 stops on it. Stop and tell the user to type
  `/flow:finish-milestone <version>`.

  For each other line, ask the user whether the mismatch is intended. If the
  user confirms every line, go to Step 3. Otherwise stop. Do not fix the
  release notes here, and do not tell the user to fix them by hand and
  push. A hand push skips the verification, and the review marker's
  `sha:` line no longer matches the branch, so `/flow:review-milestone` Step
  1 stops. End with plain text: list the lines to fix in the "Issues
  Resolved" section of `NOTES_PATH`. Then tell the user to run `/clear` and
  type `/flow:finish-milestone <version>`. Its Step 5.5 runs the same check
  and fixes the notes as a commit, it skips the steps whose results are
  still current, and its Step 10 pushes and writes a new marker. Then type
  `/flow:review-milestone <version>` (it reuses the open PR), then
  `/flow:release-milestone <version>`.
- **Exit 1 with no issue lines printed** — treat as exit 2.
- **Exit 2 with "No release notes"** — check whether an earlier run of
  the script already removed the file:

  ```bash
  git log -1 --full-history --format=%H --diff-filter=D \
    milestone/<version> -- "$NOTES_PATH"
  ```

  A SHA means the script removed the notes after an earlier confirmed
  Step 5, and then stopped before the merge. This is a resume. Skip this
  check and go to Step 3. No SHA → handle it as the exit 2 below.
- **Exit 2** — can't verify: bad arguments, no release-notes file, no
  "Issues Resolved" entries in it, a milestone with no issues (usually a
  wrong milestone number), the `gh` call failed, or a tool failed
  mid-check. Treat as "can't verify," not "clean." Stop and report the
  error. A missing notes file or a missing "Issues Resolved" section needs
  `/flow:finish-milestone <version>` (it finalizes the notes). For a wrong
  milestone number or a `gh` failure, fix the cause, then type
  `/flow:release-milestone <version>`.

`/flow:finish-milestone` Step 5.5 calls the same script earlier. This check
runs again here because the milestone PR can stay open for a while after
`/flow:finish-milestone`, and an issue's milestone assignment can change in
that window.

### Step 3: Check version consistency

```bash
flow-check-version-newer <version>
```

The script accepts a three-part version and a four-part patch-release tag
(for example `v2.30.4.1`).

- **Exit 0** — newer than the last tag. Proceed.
- **Exit 1** — not newer. Stop. Show the version and the last tag, and ask
  the user. A wrong version needs a fix to the milestone branch name and
  the release notes. A tag `<version>` on an open PR needs investigation.
  After the fix, tell the user to type `/flow:release-milestone <version>`.
- **Exit 2** — the script could not read a version. Recover in this order:
  1. If stderr says `git describe` failed, the tags are probably not
     fetched. Run `git fetch origin --tags`, then run the script again.
  2. If stderr says it could not parse the candidate version, the version
     from Step 1 is wrong. Stop and ask the user.
  3. If stderr says it could not parse the last tag, find the newest
     release tag and pass it as the second argument:

     ```bash
     git tag --list 'v*' --sort=-v:refname | head -5
     flow-check-version-newer <version> <newest-release-tag>
     ```

     Use the newest tag in the form `vX.Y.Z` or `vX.Y.Z.N`. Show the user
     which tag you used. Exit 0 or 1 from this run applies as above. If no
     tag has that form, stop and ask the user.

### Step 4: Run the release checks

Run these checks before the merge. The merge cannot be undone by running
this command again.

If the `release_checks` key is absent, add "release_checks: no key in
.claude/project.md" to the skipped list. Go to Step 5.

Run the value of `release_checks` as a shell command from the repo root, on
the milestone branch.

- **Exit 0** — the checks pass. Proceed.
- **Non-zero exit** — stop. Show the output. Do not go to Step 5. End with
  plain text: fix each failure as a commit on the milestone branch through
  `/flow:finish-milestone <version>`, then `/flow:review-milestone
  <version>`, then type `/flow:release-milestone <version>`. Do not fix it
  here, and do not push by hand.

### Step 5: Show summary and ask for confirmation

Display:

- PR number, title, and URL
- Number of commits that will be merged
- Version that will be tagged
- Release notes file path (`NOTES_PATH`)
- Remind: "This will merge the PR, delete the `milestone/<version>` branch,
  create a tag, push to origin, and publish a GitHub release (draft).
  Deployment is a separate manual step: the project's deploy procedure
  (`deploy` key)."

**Ask the user to confirm before proceeding. This is the point of no
return** — everything after this step is `flow-release-milestone` running
the merge, which cannot be undone by re-running the command.

### Step 6: Run the release script

Run it with the Bash tool `timeout: 600000`:

```bash
flow-release-milestone <version> <pr-number> <milestone-number>
```

This runs, in order: refuse to continue if local `main` carries commits
that `origin/main` does not have; save the release notes to
`<plans>/releases/<version>-release-notes.md`, remove the release-notes
file as a commit on the milestone branch and push it (so it lands inside the
PR, never as a bare push to `main` after merge); sync local `main` to
`origin/main`; merge the PR (regular merge, `--delete-branch`); pull the
merge commit; delete the local milestone branch; tag the PR's merge commit
(from `gh pr view --json mergeCommit`, not `HEAD`) `<version>` and verify
the tag points at it; push the tag; create the GitHub release as a
**draft** with `--verify-tag` from the saved notes; close the GitHub
milestone.

Exit 0 means every step above completed. Exit 1 means a check stopped the
run before it changed anything (bad args, closed PR, missing release notes,
stray local commits on `main` — the script's own output says which). The
script checks local `main` before it pushes the notes removal. Every pull is
`--ff-only`. Exit 2 means a step failed (merge conflict, push rejected, tag
on the wrong commit), or the `release_notes` or `plans` key is absent.

If the script exits non-zero, report its exact output and stop. Do not
do the remaining steps by hand. Find the cause from the output, and ask the
user before you change anything to fix it. Then run the same script
command again. If the session ended, the user types
`/flow:release-milestone <version>`: Step 1 finds the open or merged PR.
The script can resume: it skips each step whose work is already done (notes
already removed, PR already merged, tag already on the merge commit, release
already created). If the saved notes copy is missing, it restores the notes
from the commit before the removal. The confirmation in Step 5 covers the
resumed run.

After exit 0, make sure the milestone branch is gone from `origin`:

```bash
git ls-remote --heads origin milestone/<version>
```

- **Nothing prints** — the branch is deleted. Proceed.
- **A line prints** — the merge did not delete the branch. Delete it:

  ```bash
  git push origin --delete milestone/<version>
  ```

  If the delete fails, report the error and stop.

Then run `flow-milestone-count`. Show the count of milestones in progress.

### Step 7: Output summary and deploy

```text
Release <version> created
- GitHub Release (draft): <URL>
- Tag: <version> → <merge-commit>
- Milestone: closed
- Branch: milestone/<version> deleted
```

Tell the user that the project's deploy procedure (`deploy` key) deploys the
tag, never the current `main`. If the `deploy` key is present, name its
value. Otherwise, ask the user for the deploy procedure. Do not run it here.

**Publishing the release** (making it public) happens later, at deploy time,
not by this command. After the user deploys the tag, they run:

```bash
gh release edit <version> --draft=false --repo $REPO
```

Skipped steps, as this list:

```markdown
Skipped steps:
- <step>: <reason>, for example "release_checks: no key in .claude/project.md"
```

Write "Skipped steps: none" when no step skipped.

End with plain text, not a question: this milestone is done. Tell the user
to run `/clear` before the next `/flow:plan-milestone`, because this is a
milestone boundary (the `flow:workflow` skill, `SKILL.md`, "Hand-offs
between commands").
