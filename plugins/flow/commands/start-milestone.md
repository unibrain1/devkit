---
description: Begin work on a milestone by creating a milestone branch and drafting release notes
model: opus
---

# Start Milestone

Keep output brief — terse status lines, no preamble, no restating of steps.

Begin work on a milestone by creating a milestone branch from main, drafting
release notes, and recommending an issue order.

## Arguments

- `$ARGUMENTS` — the milestone version number (e.g., `v2.17.0`)

## Important

- The milestone branch is the integration point for all issue work. Individual
  issue PRs target this branch, not `main`.
- The milestone limit rule (Step 3) counts `milestone/*` branches on
  `origin`. A second parallel milestone is allowed only up to the limit for
  the repo visibility.
- This command only sets up the branch on GitHub (`origin`). It does not
  push to any other remote.
- Release notes are cumulative — each `/flow:execute-plan` run adds to them
  as work progresses (`/flow:start-issue` only plans; it doesn't touch
  release notes).
- The `plans` folder is git-ignored local scratch space, never committed.
  This command writes nothing there.

## Step 0: Project facts

1. Run `flow-project-check`. If it fails, show its output. Tell the user to
   fix `.claude/project.md` or run `/flow:setup`. Stop.
2. Read each fact that this command needs with `flow-project-fact <key>`:
   `release_notes`, `milestone_setup`, `plans`. If a key is absent, add its
   step to the skipped list.
3. Run `flow-repo`. Keep the result as `REPO`. Use `$REPO` in each command
   below.

## Step 0a: Initialize TaskList

Create one tracking task per major step below using TaskCreate (branch
creation, milestone setup, issue quality review, issue ordering,
release-notes draft, commit and push, output). Set to
`in_progress`/`completed` as you progress.

## Step 0b: Check the version

Do this before Step 1, so that a bad version stops the command before any
GitHub or git change. Check the version form, and check that the version is
newer than the last release tag. Keep the quotes: an extra word in
`$ARGUMENTS` then makes the form check fail, and it does not replace the
last tag.

```bash
flow-check-version-newer "$ARGUMENTS"
```

- **Exit 0** — continue.
- **Exit 1** — stop. Tell the user: "`$ARGUMENTS` is not newer than the last
  tag `<last tag>`. Type the command again with a newer version." The
  script's stderr names the last tag.
- **Exit 2** — read stderr:
  1. `Could not parse candidate version` — stop. Tell the user:
     "`$ARGUMENTS` is not a milestone version. Use the form
     `vX.Y.Z` or `vX.Y.Z.N`, for example `v2.17.0`, or `v2.17.0.1` for a
     patch release. Then type the command again."
  2. `git describe --tags --abbrev=0 failed` — run
     `git fetch origin --tags`, then run the check again. If it fails
     again and `git tag --list 'v*'` prints nothing, the repo has no
     release yet. Run `flow-check-version-newer "$ARGUMENTS" v0.0.0`, which
     checks only the form. Read its exit code as above. If
     `git tag --list 'v*'` prints a tag, stop and show the stderr.
  3. `Could not parse last tag` — the nearest tag is not a release tag
     (for example `skills-latest`). Run
     `git tag --list 'v*' --sort=-v:refname | head -1`. If it prints a tag,
     pass that tag as the second argument, and show the user which tag you
     used. If it prints nothing, the repo has no release yet: pass
     `v0.0.0`. Read the exit code as above. If this run also gives
     `Could not parse last tag`, stop and show the stderr.
- **Any other exit code** — stop and show the stderr.

## Workflow

### Step 1: Validate the milestone exists on GitHub

```bash
gh api "repos/$REPO/milestones?state=open&per_page=100" --paginate \
  --jq '.[] | select(.title | test("^$ARGUMENTS([: ]|$)")) | {number, title, description}'
```

A milestone title can have a suffix after the version, for example
`v2.31.0: Reachable Owners and Findable Cars`.

- **One result** → record the number as `<NUMBER>`, the full title as
  `<MILESTONE_TITLE>`, and the description. Later steps use them.
- **No result** → stop. Show the open milestone titles. Tell the user: "Type
  `/flow:plan-milestone $ARGUMENTS`. It offers to create the milestone and
  seals its issue list."
- **More than one result** → stop. Show the titles. Tell the user: "Rename
  or close the extra milestone on GitHub, then type
  `/flow:start-milestone $ARGUMENTS`."

```bash
gh api "repos/$REPO/milestones?state=open&per_page=100" --paginate --jq '.[].title'
```

### Step 2: Ensure clean working tree

```bash
git status --porcelain
```

If there are uncommitted changes, stop. Tell the user: "Commit or stash the
changes, then type `/flow:start-milestone $ARGUMENTS`."

### Step 3: Create the milestone branch from main

The repo can have more than one local clone that shares the same `origin`.
A local `git branch --list 'milestone/*'` only sees branches in *this*
clone. It can miss a milestone branch that is active in another clone. Check
for THIS milestone first, locally and on `origin`:

```bash
flow-find-milestone-branch $ARGUMENTS
```

- **Exit 0** — a `milestone/$ARGUMENTS` branch already exists (locally, on
  `origin`, or both — the script prints the branch name either way). Don't
  create a duplicate — check it out locally instead (do not check out a
  `milestone/*` branch as a `git worktree` of another local clone; get it
  from `origin` directly):

  ```bash
  git fetch origin milestone/$ARGUMENTS
  git checkout -b milestone/$ARGUMENTS origin/milestone/$ARGUMENTS
  ```

  Skip the `checkout -b` line if the branch already exists locally too —
  just `git checkout milestone/$ARGUMENTS` and pull.

- **Exit 1** — no branch for this exact milestone exists yet. Apply the
  milestone limit rule (the `flow:workflow` skill, `references/plan.md`,
  "Milestone limit"):

  ```bash
  flow-milestone-count --check
  ```

  - **Exit 1** — the repo is at its limit. The limit is 1 milestone in
    progress for a private repo and 2 for a public repo. Stop. Show the
    count from stdout and the reason from stderr. Tell the user: "Run
    `/flow:release-milestone` for a milestone in progress, then type
    `/flow:start-milestone $ARGUMENTS`."
  - **Exit 2** — the check failed. Stop. Show the error.
  - **Exit 0** — the repo is under its limit. Create the branch from
    `main`:

    ```bash
    git checkout main
    git pull origin main
    git checkout -b milestone/$ARGUMENTS
    git push -u origin milestone/$ARGUMENTS
    ```

- **Exit 2** — usage error. Stop. Tell the user: "Type
  `/flow:start-milestone <version>`, for example
  `/flow:start-milestone v2.17.0`."

### Step 3.5: Run the milestone setup

If the `milestone_setup` key is absent, add "milestone_setup: no key in
.claude/project.md" to the skipped list. Go to Step 4.

Otherwise, run the value of `milestone_setup` as a shell command from the
repo root. A non-zero exit stops this command. Show the output to the user.

If the command changed tracked files, show `git status --short` to the user.
Step 6.5 requires a clean working tree before it pushes. Ask the user
whether to commit the changes as the first commit on the milestone branch.
Commit them only if the user agrees.

### Step 4: List the milestone's open issues

```bash
gh api "repos/$REPO/issues?milestone=<NUMBER>&state=open&per_page=100" --paginate \
  --jq '.[] | select(.pull_request == null) | {number, title, labels: [.labels[].name], body}'
```

Use the direct API call, not `gh issue list --milestone` (the `flow:workflow`
skill, `references/github.md`, "gh CLI gotchas"). Use the API result as the
authoritative issue list.

Then check whether `/flow:plan-milestone` sealed this milestone. Its Step 4
leaves two marks: the milestone description is the theme sentence, and every
open issue in the milestone has `status:ready`. Count the open issues
without that label:

```bash
gh api "repos/$REPO/issues?milestone=<NUMBER>&state=open&per_page=100" --paginate \
  --jq '.[] | select(.pull_request == null) | select([.labels[].name] | index("status:ready") | not) | .number' \
  | wc -l
```

The milestone is sealed when all of these are true:

- The milestone has at least one open issue.
- The count is `0`.
- The description from Step 1 is one sentence that names an audience and
  an outcome. A category name, an issue list, or an empty description does
  not count.

**Sealed** → print "Sealed by /flow:plan-milestone. Skipping gate." Skip
Steps 4.4 and 4.5. The description is the theme sentence. Continue to Step 5.

**Not sealed** → continue to Step 4.4.

### Step 4.4: State the milestone theme

Before reviewing the issues, state what this release is *for*, in one sentence
naming an audience and an outcome:

> "An owner can manage their own car photos without emailing an admin."
>
> "A visitor arriving from a search engine lands on something that makes
> sense."

Not a category. "Photo improvements" has no audience, no outcome and no finish
line — and a milestone without a finish line drifts until the list is empty
rather than until the work is done.

`/flow:plan-milestone` did not run, so it did not read the last
retrospective. Read the newest one here, if one exists. If the `plans` key
is absent, add "retrospective: no `plans` key" to the skipped list. Else run:

```bash
find "$(flow-project-fact plans)/releases" -name '*-retro.md' 2>/dev/null | sort -V | tail -1
```

`/flow:finish-milestone` Step 6.5 writes this file. It holds three answers,
in this order: what we shipped that nobody needed, what we learned about the
theme's audience, and which signal we ignored. Show all three answers before
you ask for the theme. Step 4.5 uses the first answer. No file → say "No
retrospective found." and continue.

Ask the user:

> "State this milestone's theme in one sentence — who it's for, and what they
> can do afterwards that they can't do now. I'll test every issue against it."

Record the answer. It becomes the yardstick for Step 4.5 and the release
criterion: **the milestone ships when the theme sentence is true, not when
the issue list is empty.**

Then make it the milestone description on GitHub:

```bash
gh api repos/$REPO/milestones/<NUMBER> -X PATCH \
  -f description="<theme sentence>"
```

### Step 4.5: Issue quality review

This is the lighter-weight fallback of `/flow:plan-milestone` Step 3's gate,
for a milestone that reached `/flow:start-milestone` without
`/flow:plan-milestone` sealing it first (the `flow:workflow` skill,
`references/plan.md`, "Unsealed milestone"). Run the same gate here: the
three questions (who noticed? / what do they do today instead? / what breaks
if this never ships?), the edge-case test, and the inclusion question
("which of these serve the theme?" — default is out, not in). If the
retrospective from Step 4.4 names work that nobody needed, an issue of the
same kind must show a stronger signal to stay. A `signal:defect` issue that
a user can see (an owner, a visitor, or an admin or editor in the site UI)
stays in without the theme test, and counts toward the theme issues. Show it
to the user with the signal `signal:defect (user-visible)`. Cap: **3–6 theme
issues, plus at most one housekeeping (`signal:forced`) issue, plus every
open `gate-critical` issue** (uncapped, bypasses the theme test).

Deltas from `/flow:plan-milestone` Step 3, since this gate runs after issues
already have implementation detail to judge:

- Also flag: **make-work** (no real value, cosmetic-only), **trivial tests**
  (delegation/passthrough only, no realistic failure mode), **already
  superseded** (resolved by other recent work), **duplicate scope** (two
  issues, same root problem).
- Also produce a **consolidation candidates** list: issue groups touching the
  same 1–2 files, small enough that separate PRs add overhead without
  benefit. Recommendation only.

**If either gate's criteria change, update both** — a milestone that skipped
`/flow:plan-milestone` should not get a meaningfully different bar.

Output format:

```text
## Issue Quality Review

### Flag for potential closure
| # | Title | Reason |
|---|-------|--------|
| #NNN | ... | one sentence |

### Consolidation candidates
- #NNN + #NNN: both touch [file], small scope, natural pair
- (none)
```

Ask inclusion first:

> "Which of these serve the theme? List the numbers. Anything you don't list
> comes out of the milestone — deferred, not closed."

Defer (leaves the issue open, out of the milestone):

```bash
gh issue edit NNN --repo $REPO --remove-milestone
```

Close (fails all three planning questions outright). Remove the milestone,
then close the issue as not planned. If the milestone edit fails, do not
close the issue. Report the failure:

```bash
gh issue edit NNN --repo $REPO --remove-milestone
gh issue close NNN --repo $REPO --reason "not planned" \
  --comment "Closing as low-value / make-work during milestone planning. Can be reopened if prioritized."
```

Remove closed/deferred issues from the working list before proceeding.

If more than six theme issues survive, ask the user which six take priority;
the remainder return to the backlog.

If consolidation candidates exist, ask second:

> "Which consolidation groups (if any) should I merge into a single issue? List
> the group numbers (e.g., '1, 3') or press Enter to keep all as separate issues."

For each accepted group: pick the primary issue (more complete scope, or
lower number if unclear — ask the user if not obvious), fold the secondary
issue's scope into its body. Then remove the milestone from the secondary,
and close it as a duplicate of the primary, with a linking comment. If the
milestone edit fails, do not close the issue. Report the failure:

```bash
gh issue edit NNN --repo $REPO --remove-milestone
gh issue close NNN --repo $REPO --duplicate-of PRIMARY \
  --comment "Consolidated into #PRIMARY — scope merged there."
```

Remove secondary issues from the working list. The primary carries the full
combined scope into Step 5.

Then scope each issue that stays. `/flow:start-issue` needs acceptance
criteria and `status:ready` on each issue. Apply `/flow:plan-milestone`
Step 4, items 1 to 4, to each issue in the working list:

1. Write the acceptance criteria.
2. Add them to the issue body as an `## Acceptance criteria` section.
3. Give the title its scoped type, apply `status:ready`, and remove
   `triage`. The issue is already in the milestone, so leave out
   `--milestone`:

   ```bash
   gh issue edit NNN --repo $REPO --title "<type>: <description>" \
     --add-label "status:ready" --remove-label "triage"
   ```

4. For an issue scoped down to the guard only, post the scope comment.

Skip an issue that already has an `## Acceptance criteria` section that
matches the theme and `status:ready`.

### Step 5: Recommend an issue order

Step 6 stores the approved order in the release notes: the `WIP:` entries
of the "Issues Resolved" section go in that order. After each merge,
`/flow:finish-issue` names the first `WIP:` entry whose issue is open and
does not have `status:blocked` (the `flow:workflow` skill,
`references/plan.md`, "Issue order and blockers").

Launch the `flow:senior-product-manager` agent to analyze all issues and
determine the best sequence. Consider:

- **Dependencies** — issues that other issues depend on should come first
  (e.g., a schema change before a feature that uses it)
- **Severity** — CRITICAL before HIGH before MEDIUM before LOW
- **Shared code paths** — group issues that touch the same files to minimize
  merge conflicts
- **Foundation first** — infrastructure/config changes before
  application-level changes
- **Consolidations already resolved** — secondary issues were closed in Step
  4.5; the primary issue carries the full merged scope and appears as a normal
  single entry in the sequence

Synthesize agent recommendations into a numbered list with a brief rationale
for each position. Also list:

- **Order conflicts** — an issue that must not start until another issue
  closes. The stored order does not stop a developer who types
  `/flow:start-issue` for that issue, so the issue also needs
  `status:blocked`.
- **Combine groups** — issues that touch the same code and must land as one
  PR. `/flow:plan-milestone` Step 4 may already have posted these. Read the
  issue comments for the phrase `Combine into one PR with`.

Ask the user to approve the order:

> "Approve this issue order? Reply yes to continue, or list changes."

After approval, record on GitHub what the order needs, so that later
sessions see it:

- For each order conflict, add `status:blocked` and a comment that names
  the blocker. Remove the label when the blocker closes.

  ```bash
  gh issue edit NNN --repo $REPO --add-label "status:blocked"
  gh issue comment NNN --repo $REPO --body "Blocked by #BLOCKER (planned in $ARGUMENTS)."
  ```

- For each new combine group, post one comment on each issue in the group.
  Use exactly this phrase, because `/flow:start-issue` reads it. Skip an
  issue that already has the comment.

  ```bash
  gh issue comment NNN --repo $REPO --body "Combine into one PR with #A, #B (planned in $ARGUMENTS)."
  ```

  On each issue, list the other issues of the group, not the issue itself.

### Step 6: Create draft release notes

If the `release_notes` key is absent, add "release notes: no
`release_notes` key in .claude/project.md" to the skipped list. Skip Steps
6 and 6.5. Go to Step 7.

Replace `{version}` in the value of `release_notes` with `$ARGUMENTS`. Call
the result `NOTES_PATH`.

If `NOTES_PATH` already exists, do not change it. Print "Release notes
already exist at `NOTES_PATH`. Left unchanged." Continue to Step 6.5.

Otherwise, create a draft release notes file at `NOTES_PATH`. Use the
release notes template that the project's CLAUDE.md names. If it names none,
use these sections: summary, "Issues Resolved", deployment instructions, and
verification.

- Fill in the version and today's date
- Write a summary of at most 2 sentences based on the milestone
  description
- Populate the "Issues Resolved" section with all open issues from the
  milestone, in the order approved in Step 5, not sorted by number. Put the
  issues of a combine group next to each other. `/flow:finish-issue` reads
  this order to name the next issue. Link each entry to
  `https://github.com/$REPO/issues/NNN`. Prefix each entry with `WIP:`,
  since none are actually resolved yet at milestone creation — e.g.
  `WIP: [#423](https://github.com/$REPO/issues/423) — Issue title`.
  `/flow:execute-plan` fills in each issue's real changes as that issue is
  implemented, and `/flow:finish-issue` strips this issue's own `WIP:`
  prefix once its PR is merged and the issue closed — the prefix is what
  lets `/flow:finish-milestone` later verify every planned issue actually
  finished, not just that the right issues are listed.
- Leave deployment instructions and verification sections as template
  placeholders — these will be filled in as issues are completed
- Remove any template-instructions section from the file

Use the `flow:technical-documentation-writer` agent if the milestone has many
issues or complex scope.

### Step 6.5: Commit and push the milestone branch

`/flow:start-issue` stops when `git status --porcelain` prints anything. The
release notes file is tracked, not ignored, so commit it now:

```bash
git add "$NOTES_PATH"
git commit -m "docs: draft release notes for $ARGUMENTS"
git push origin milestone/$ARGUMENTS
```

If the file did not change (the branch already had it), skip the commit and
still push. The push also sends the Step 3.5 commit, if there is one. Then
check the result:

```bash
git status --porcelain
git rev-list --count origin/milestone/$ARGUMENTS..HEAD
```

The first command must print nothing and the second must print `0`. If not,
stop and show the output. Tell the user: "Commit or push the changes shown,
then type `/flow:start-milestone $ARGUMENTS`. Step 3 finds the existing
branch and Step 6 keeps the existing release notes."

### Step 7: Output summary

Display:

- The milestone branch name (`milestone/$ARGUMENTS`)
- How many issues were closed in the quality review (if any), or that Step 4
  found the milestone sealed and skipped the gate
- Any consolidation opportunities flagged (if not already addressed by the user)
- The approved issue order (from Step 5)
- The issues that got `status:blocked` and the combine groups commented on
  (Step 5)
- Whether Step 6 created the draft release notes at `NOTES_PATH` or left an
  existing file unchanged, and that Step 6.5 committed and pushed the branch
- Skipped steps, as this list:

  ```markdown
  Skipped steps:
  - <step>: <reason>, for example "milestone_setup: no key in .claude/project.md"
  ```

  Write "Skipped steps: none" when no step skipped.

End with the next command as plain text, not a question. GitHub and the
release notes hold the state, so tell the user to run `/clear`
first and then type `/flow:start-issue <first-issue>`. Do not start it
through the Skill tool. This is a context boundary (the `flow:workflow`
skill, `SKILL.md`, "Hand-offs between commands").
