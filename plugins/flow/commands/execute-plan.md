---
description: Execute an approved plan file from /flow:start-issue — implementation, tests, and reviews
model: opus
---

# Execute Plan

## Step 0: Project facts

1. Run `flow-project-check`. If it fails, show its output. Tell the user to
   fix `.claude/project.md` or run `/flow:setup`. Stop.
2. Read each fact that this command needs with `flow-project-fact <key>`.
   This command needs these keys:
   - `plans` — the plan folder. If the key is absent, tell the user to add
     `plans` to `.claude/project.md`. Stop.
   - `test`, `test_quick`, `lint` — the test and lint commands. During this
     command, run `test_quick` if the key exists, else `test`.
   - `issue_checks` — optional. If it is absent, add "issue checks: no
     `issue_checks` key in .claude/project.md" to the skipped list.
   - `release_notes` — optional. If it is absent, add "release notes: no
     `release_notes` key in .claude/project.md" to the skipped list.
   - `ledger` — optional. If it is absent, add "ledger checks: no `ledger`
     key in .claude/project.md" to the skipped list.
   - `standards` — optional. The coding standards files for the reviewers.
3. Run `flow-repo`. Keep the result as `<repo>` in the `gh` commands below.

In this file, `<plans>` is the value of the `plans` key.

Keep output brief — terse status lines, no preamble, no restating of steps.

## Hard Constraints (non-negotiable)

> **1. THE PLAN FILE MUST BE APPROVED before this command implements anything.**
> If the plan file's status line is not `Approved`, stop and tell the user to
> run `/flow:start-issue` to finish planning and approval first. Step 2 gives
> the one exception: a plan that a previous run marked `Implemented`.
>
> **2. NEVER commit, push, or create PRs.**
> After implementation is complete, stop. The user types `/commit`, then
> `/flow:review-pr` (Step 9). Do not run `git add`, `git commit`, or
> `git push` under any circumstances during this workflow.

---

This command implements an approved plan file written by
`/flow:start-issue`. It re-verifies the plan's checklist against actual repo
state before doing any work, so it is safe to run on a fresh branch, resume a
partially-completed plan, or be run by a second agent/session picking up
after an interruption — in every case it establishes ground truth from the
files themselves, not from assumptions about what "should" have happened.

**Find issues at the earliest, least expensive stage.** A bug found here —
implementation time, one file open, full context loaded — costs one fix. The
same bug found at `/flow:review-pr` costs a fix plus a re-verify round-trip;
found after merge it costs a follow-up issue. Step 6 below specifically calls
out two risk classes (new database queries, structured-input validation) that
reading code carefully does not reliably catch — only running the code does —
so treat "looks correct on inspection" as provisional for those two classes,
and execute before checking the item off.

## Arguments

- `$ARGUMENTS` — (optional) an issue number or a path to a plan file. If
  omitted, auto-detect from the current branch name (e.g.,
  `issue/423-car-data-export` → `<plans>/issues/issue-423-car-data-export.md`),
  the same inference `/flow:finish-issue` uses.

## Step 0b: Initialize TaskList

Create tasks: locate + validate plan file, re-verify checklist against repo
state, execute remaining items (fanned out per plan annotations), run
test/issue-checks/ledger steps, update release notes, run the
simplify pass, run the review round and record the fingerprint, confirm the
checklist, final hand-off summary. Set each `in_progress`/`completed` as you progress.

## Workflow

### Step 1: Locate the Plan File

If `$ARGUMENTS` is a path ending in `.md`, use it directly and read its
`**Status:**` line yourself (skip to Step 2's branching logic). Otherwise run:

```bash
flow-check-plan-state $ARGUMENTS   # $ARGUMENTS may be empty
```

This derives the issue number from the branch name when `$ARGUMENTS` is
empty (the same way `/flow:finish-issue` does), locates
`<plans>/issues/issue-<NUMBER>-*.md` (or the older
`<plans>/issue-<NUMBER>-*.md`), and reports its path, approval state, and
checklist progress.

- **Exit 0** — plan found and approved. Proceed to Step 3 (Step 2 is already
  satisfied).
- **Exit 1** — no plan file found. Stop and tell the user: "No plan file
  found for this issue in this checkout. The `plans` folder is git-ignored,
  so each clone and worktree has its own copy. If you planned this issue in
  a different clone or worktree, run `/flow:execute-plan` there. Otherwise,
  run `/flow:start-issue <NUMBER>` first."
- **Exit 2** — plan file found but not approved. Proceed to Step 2, which
  resumes an `Implemented` plan and stops on any other status.
- **Exit 3** — could not derive an issue number (no `$ARGUMENTS`, and the
  current branch name doesn't match `issue/`, `bug/`, or `feature/`). Ask the
  user for the issue number or plan file path.
- **Exit 10** — no `plans` key. Step 0 stops on this case already.

If the `path:` line lists more than one file (comma-separated — a stale plan
from an earlier, differently-named attempt), list them and ask the user
which to use.

### Step 2: Validate Approval Status

Do this step on exit 2 from Step 1, and when `$ARGUMENTS` is a plan file
path. Read the plan file's `**Status:**` line directly to see what it is:

- **`Approved — ready for /execute-plan`** (a path argument only): go to
  Step 3.
- **`Draft — pending approval`**: stop. Tell the user: "This plan is not
  approved yet. Type `/flow:start-issue <NUMBER>`. It finds the existing
  branch and plan and continues at its approval step (Step 9)."
- **`Implemented — pending commit/PR`**: a previous run reached Step 8.
  Run Step 3. If every item is verified done or marked N/A (Step 8, "The
  N/A marker"), and the release notes have this
  issue's entry (Step 6.7), go to Step 9. A hotfix plan (it has the line
  ``**PR base:** `main` ``) has no release-notes entry, so for a hotfix plan
  check only the items. If the `release_notes` key is absent, check only the
  items. If not, set the status line back to
  `**Status:** Approved — ready for /execute-plan` and continue from Step 4.
- **Anything else** (e.g. already marked complete, or an unrecognized value):
  stop and show the user the actual status line, ask how they want to
  proceed — do not guess.

### Step 3: Re-Verify Checklist Against Repo State

This is the step that makes the plan file trustworthy to any agent or session
that picks it up — never assume the checklist's `[ ]`/`[x]` marks reflect
reality; confirm each one against the actual repository.

For each checklist item:

- **N/A items** (the line ends with `— N/A: <reason>`, Step 8): count the
  item as done. Do not do it, and do not tick it. Step 4 does not schedule
  it.
- **File-creation/modification items** ("Add X to file"): check whether
  the described change is actually present in the file (grep for the
  function/method/class name, or read the relevant section).
- **Test items** ("Add a unit test for X"): check whether the test file and
  the specific test method exist.
- **Review items** ("Run security-review", "Run senior-architect review"):
  these cannot be verified by file inspection alone — treat as done only if
  the plan file's checklist already shows `[x]` AND a later step in this same
  workflow run didn't just invalidate that review by changing the reviewed
  files. If uncertain, re-run the review rather than trust a stale checkmark.

Produce a status report: which items are genuinely done (matches both the
checkbox and the actual repo state), which are marked done but aren't
actually present (repo state contradicts the checkbox — flag this explicitly,
it means a previous run's edit was reverted, lost, or never actually
committed to disk), and which are genuinely not started.

**If any item is marked `[x]` but repo state contradicts it**, use
AskUserQuestion before proceeding — do not decide this yourself and do not
silently re-do or silently trust the checkbox:

- Question: "Plan says '`<item>`' is done, but I don't see it in `<file>`.
  How should I proceed?"
- Options: `Treat as not done, redo it` (recommended), `It's actually done —
  update the checkbox, don't redo`, `Let me look myself first`

This discrepancy is exactly the kind of drift the re-verification step
exists to catch, so it always goes to the user — never resolved
automatically, since only they can know whether the missing evidence means
lost work or a false-positive check in the earlier run.

Update the plan file's checkboxes to match verified reality before continuing.

### Step 4: Determine Fan-Out from Plan Annotations

Group the remaining (`[ ]`) checklist items by their annotations. Leave
out the N/A items (Step 3).

- Items marked `(parallel-safe)` with no unresolved `(depends on: ...)` can
  run concurrently — launch one `flow:software-developer` agent per
  independent file or group of related files.
- Items marked `(depends on: <other item>)` wait until that item is verified
  complete (Step 3) or completed earlier in this same run.
- If the plan gives no annotation for an item (older plan file, or an
  oversight), treat it conservatively as **not** parallel-safe — run it
  sequentially rather than guess.

### Step 5: Implement

Launch `flow:software-developer` agents per Step 4's grouping. Provide each agent:

- The specific checklist item(s) it owns, verbatim from the plan file
- The plan's Architecture & Design section for context
- Any Database & Security Considerations relevant to its files
- This instruction: "If the item needs a change the plan does not list (a
  file outside the plan, a different approach, a dropped requirement), do
  not make it. Stop and report it." Then apply the deviation rule below.
- For an item that writes user-facing text about a rule (which mail an
  owner gets, who sees what, what a flag stops): the rule itself, as a
  table from the code or the plan, and this instruction: "Check each
  sentence against the table. Write only what the table makes true for
  every user who sees the sentence." A sentence that is true for one kind of
  user can be false for another kind. A reviewer can find it only in a late
  review round.

**One writer per file.** Two agents that run at the same time must not
edit the same file. This includes the temporary edits that prove a test
can fail (Step 6). Before you launch an agent, list the files it may edit.
If another running agent may edit one of them, wait for that agent or give
both items to one agent. When you launch a test agent while another agent
runs, write in its prompt: "Other agents are running. Do not stash or
overwrite a file to prove a test."

**Model override by tier** (infer tier from the plan file's scope — number of
checklist items and files touched, same Small/Medium/Large bands
`/flow:start-issue` used): pass `model: "sonnet"` for Small-tier plans. Omit
`model` for Medium/Large (agent default is Opus).

As each agent completes, mark its checklist item(s) `[x]` in the plan file
immediately — do not batch updates to the end. This is what lets a second
agent or a later session trust the file's state without re-running Step 3
from scratch.

**Ledger items.** When you fix an item from the plan's `## Ledger items`
section, in the same branch:

1. Delete the item's line from the `ledger` file. If its `###` heading has
   no items left, delete the heading too.
2. Tick the item's line in the plan's `## Ledger items` section (`- [x]`).

**Deviation rule.** If the work needs a change that the plan did not
approve (a file outside the plan, a different approach, a dropped
requirement, a new dependency), stop all implementation. Do not make the
change. Then:

1. Add a `## Deviation` section to the plan file, below the header. State
   the change, why the plan cannot work without it, and the checklist items
   it adds or changes. Write each added item in the checklist item form,
   with its file and its parallel-safety annotation. Do not edit the
   Implementation Checklist. `/flow:start-issue` ("Merge a deviation")
   merges these items into it, pulls the ledger items for the new files,
   and sets the risk flag again. Then the user approves the merged plan.
2. Post a comment on the issue that states the deviation and asks for
   re-approval:
   `gh issue comment <NUMBER> -R <repo> --body "<text>"`.
3. Set the plan's status line to `**Status:** Draft — pending approval`.
4. Tell the user as plain text: "The plan needs re-approval. The plan file
   holds the state, so you may run `/clear` first. Type
   `/flow:start-issue <NUMBER>`. It continues at its approval step. Then type
   `/flow:execute-plan <NUMBER>`." Then stop. Leave the work done so far
   uncommitted.

### Step 6: Test, Security, Documentation

Launch in parallel, only the agents relevant to what changed (per the plan's
Test Plan / Documentation Plan sections):

- **`flow:senior-test-engineer`**: write and run tests from the plan's Test
  Plan. Use separate instances for each test tool if more than one applies.
- **`flow:technical-documentation-writer`**: update docs per the plan's
  Documentation Plan.

Run quality checks: the `test_quick` command (or `test`, if the key is
absent) and the `lint` command (run each with the Bash tool
`timeout: 600000`).

**Execute, don't just read, for two specific risk classes.** Two kinds of
bugs reach `/flow:review-pr` that a careful code-review pass misses
entirely, because nothing actually *ran* the risky code path — the plan and
the implementation both read as correct, and only execution surfaces the
defect. Both are cheap to catch here instead of two workflow stages later:

- **New or changed database queries**: if this plan added or modified a
  query, run it against a real local database (even one with zero matching
  rows is enough to prove the query itself is syntactically and
  semantically valid under the project's actual SQL mode and column types)
  before marking the item done. A query that "looks correct" on inspection
  can still be a guaranteed fatal error against the real schema — e.g.
  comparing a `DATE` column to `''` under a strict SQL mode throws, but no
  static read of the query reveals that; only executing it does. Include
  the exact command/output as evidence when checking off the item, not just
  "looks right."
- **Any new public method that accepts structured input** (an array, a DB
  row, JSON-decoded data) from a caller who might build that input
  dynamically rather than as a literal: instruct the
  `flow:senior-test-engineer` to include, alongside the tests the plan's
  Test Plan already calls for, at least one test per structured parameter
  that passes a **malformed or wrong-typed** value (not just a missing key)
  and asserts the method's own documented failure mode — not merely "no
  crash." Static analysis only catches violations at call sites it can see;
  it cannot catch a shape violation in data assembled at runtime, which is
  exactly the gap a caller loop or DB row can fall into. Concretely: a
  method that takes a record with a string `label` needs a test passing a
  number as `label`, not just a test omitting `label` entirely — a
  present-but-wrong-typed value can reach a strictly-typed helper uncaught
  and throw a generic type error instead of the method's documented
  exception, and only a test that supplies the wrong type (not just the
  absent key) will catch it.
- **Every new test**: the `flow:senior-test-engineer` must show that each new
  test fails with the change reverted. A test that passes with the change
  reverted must guard behavior that must not change, and the report must say
  so. Do not mark a test item `[x]` until the plan file records the result
  for each test, in the form `fails without the change` or
  `passes without the change — <reason>`.
- **Prove a test can fail on a copy, not on the real file.** When a test
  can read its input from a path (for example, a source test that takes its
  directory from an environment variable), the test agent points it at a
  copy of the old file. When the test must run the real file and another
  agent runs at the same time, the test agent does not prove it. It reports
  the test as not proved.
- **A test the agent could not prove.** Keep its item `[ ]`. When no
  running agent may edit the file ("One writer per file", Step 5), run the
  proof yourself:
  1. Copy the current file to your scratchpad.
  2. Write the old version over it:
     `git show <merge-base>:<file> > <file>`. For a file that the change
     adds, move it to the scratchpad.
  3. Run the test. Record `fails without the change` or
     `passes without the change — <reason>` in the plan file.
  4. Restore the file with `cp` from the scratchpad copy. Check it with
     `diff` against that copy. Then mark the item `[x]`.

Mark the corresponding checklist items `[x]` as each completes.

### Step 6.4: Resolve the Base Ref

Steps 6.5, 6.6, 6.7 and 7 use one base ref. Resolve it once, here. First
check for a hotfix plan:

```bash
grep -F '**PR base:** `main`' <plans>/issues/issue-<NUMBER>-<slug>.md
```

- **The line is there** — this is a hotfix plan. The base ref is
  `origin/main`. Do not read the `**Milestone:**` field. A hotfix plan has
  `none (hotfix)` there.
- **The line is not there** — get the milestone branch from the plan's
  `**Milestone:**` field:

  ```bash
  sed -n 's/^\*\*Milestone:\*\* `\([^`]*\)`.*/\1/p' <plans>/issues/issue-<NUMBER>-<slug>.md
  ```

  The base ref is `origin/<milestone-branch>`. If the field is missing (an
  older plan file, or one edited by hand), run
  `git branch --list 'milestone/*'`. If exactly one branch exists, use it.
  If zero or more than one exist, stop and ask the user which milestone
  branch this issue belongs to. Do not guess.

The steps below write this value as `<base-ref>`.

### Step 6.5: Issue Checks

If the `issue_checks` key is absent, skip this step. The skipped list has
it already (Step 0). Go to Step 6.6.

Run the `issue_checks` command from the repo root, with the Bash tool
`timeout: 600000`. Give it the changed file names on stdin, one name on
each line. This command does not commit, so the changes are in the working
tree. Run the check now, right after implementation, while context is fresh.

```bash
{ git diff --name-only HEAD; git ls-files --others --exclude-standard; } \
  | sort -u | <issue_checks command>
```

Replace `<issue_checks command>` with the value of the `issue_checks` key.

- **Exit 0** — clean. Proceed to Step 6.6.
- **Any other exit code** — stop. Show the output to the user. Fix what the
  check reports if the fix is in the plan's files. If the fix needs a file
  outside the plan, apply the deviation rule (Step 5). Run the check again.
  Do not go on while it exits non-zero.

### Step 6.6: Cleanup Ledger Check

If the `ledger` key is absent, skip this step. The skipped list has it
already (Step 0). Go to Step 6.7.

**Hotfix plans skip this step** (the plan has the line
``**PR base:** `main` ``). A hotfix fixes only the emergency, so it takes no
cleanup items. Go to Step 6.7.

`/flow:start-issue` ("Pull ledger items") pulls ledger items known at
plan-approval time into the plan's **Ledger items** section and the
Implementation Checklist. This step catches two gaps that step can't: an
item added to the ledger *after* this plan was approved, and a file this
implementation ended up touching that the plan didn't foresee touching.

The file list comes from the working tree: tracked changes since the merge
base, plus untracked files.

```bash
set -o pipefail
MERGE_BASE=$(git merge-base HEAD <base-ref>)
[ -n "$MERGE_BASE" ] || { echo "no merge base with <base-ref>" >&2; exit 3; }
{ git diff --name-only "$MERGE_BASE" && git ls-files --others --exclude-standard; } \
  | flow-ledger-items-for-files
```

The script reads the `ledger` file. Items that Step 5 fixed are already
deleted from it, so they do not show here.

- **Exit 0, no output** — clean. Proceed to Step 6.7.
- **Exit 0, every line is in the plan's Ledger items section** — the plan
  approved these items and they are not fixed yet. Fix each one now, as in
  Step 5 ("Ledger items"), or mark it N/A in Step 8. Proceed to Step 6.7.
- **Exit 0, a line not in the plan** — offer it, don't fix it
  unconditionally and don't silently skip it. For each new item, in order:
  state the file and item text, then AskUserQuestion: "`<file>` has an
  open cleanup-ledger item not in this plan: `<item text>`. Fix it in this
  PR?" Options: `Fix now` (recommended only when the fix is small and
  doesn't expand scope beyond the plan's files), `Add to plan and fix now`
  (recommended when it's larger — updates the Implementation Checklist
  first, then fixes), `Leave for its own PR`. Act on the answer: `Fix now`
  or `Add to plan and fix now` — fix it, delete its line from the ledger
  file as in Step 5, then add the item to the plan's `## Ledger items`
  section as ``- [x] <item text> — `<path>` ``, word for word;
  `Leave for its own PR` — no action here, it stays in the ledger for a
  future branch that's asked the same way.
- **Exit 2** — the ledger file is missing or unreadable. Treat it as
  "can't verify," not "clean". Tell the user and continue. This check does
  not block the rest of the workflow.
- **Exit 1** — usage error. Correct the input and run it again.
- **Exit 3** — no merge base. Stop and tell the user. The base ref from
  Step 6.4 is wrong, or the branch does not share history with it.
- **Exit 10** — no `ledger` key. Step 0 skips this step already.
- **Any other exit code** — a `git` command failed. Treat it as "can't
  verify," not "clean". Show the user the stderr and continue.

### Step 6.7: Update Draft Release Notes

If the `release_notes` key is absent, skip this step. The skipped list has
it already (Step 0). Go to Step 6.8.

Do this before Step 7, so the reviewers see the release notes and the Step 7
fingerprint includes them.

**Hotfix plans skip this step.** If Step 6.4 found a hotfix plan, the issue
ships as a patch release from `main`, not with a milestone. Do not touch any
milestone release notes. Go to Step 6.8.

Otherwise, use the milestone branch that Step 6.4 resolved. The version is
the branch name without `milestone/` (`milestone/v2.17.0` → `v2.17.0`).
Update the file that the `release_notes` key names, with `{version}`
replaced by the version. If the file does not exist yet, ask the user for the
release notes template, then create the file from it. Add this issue's
changes to the appropriate section and keep it cumulative. Keep the entry
brief: at most one entry for this issue in the sections for user-visible or
admin-visible changes, one sentence of at most 20 words. A change with no
visible effect gets no entry there.

### Step 6.8: Simplify Pass

Invoke the `simplify` skill through the Skill tool. It reviews the changed
code for reuse, simplification, and efficiency, and edits the files. Run it
here, before Step 7, so the Step 7 reviewers see the simplified code and the
Step 7 fingerprint still matches at hand-off.

After the skill returns, run the `test_quick` command (or `test`, if the key
is absent) again, with the Bash tool `timeout: 600000`.
If a test fails, fix the simplification or revert it. If the skill edited a
file that the plan does not list, revert that edit (Step 5, "Deviation
rule").

### Step 7: The single review round — all reviewers, in parallel, before the push

**Launch every applicable reviewer at once, against the same commit.** Not in
sequence, and not spread across the push:

- **`flow:senior-architect`** — the complete diff: architecture fit, code
  quality, standards adherence, documentation completeness. The agent default
  is Sonnet. Pass `model: "opus"` for Large-tier plans only.
- **`flow:security-reviewer`** — if the plan's Database & Security
  Considerations section is non-empty, or any changed file touches forms,
  database queries, or auth.
- **`flow:code-reviewer`** — conformance with CLAUDE.md, the `standards`
  files, and the project's `.claude/rules/`.
- **`flow:pr-test-analyzer`** — coverage of the plan's acceptance criteria.
- **`flow:silent-failure-hunter`** — if the diff adds or changes any catch
  block, fallback, or error path, **or** adds a new public method with
  structured-input parameters (array/DB row/JSON) or new/modified database
  queries. That second trigger is the class of issue architect review
  (design/security/coverage-focused) can miss: a wrong-typed value reaching a
  strictly-typed private helper as an uncaught type error instead of the
  method's documented exception. Skip when neither condition applies — it is
  not a blanket addition to every plan.
- **`flow:type-design-analyzer`** — if the diff introduces a new class,
  value object, or DTO — not for changes confined to existing classes'
  method bodies.
- **`flow:senior-ux-designer`** — if the diff adds a new screen or page
  section, extracts or restructures a shared UI partial, or changes button
  hierarchy/placement/visibility rules — not for copy-only or styling-only
  tweaks to an existing, unchanged layout.
- **`flow:comment-analyzer`** — if the diff adds or changes doc blocks,
  inline comments, or docstrings. Run the independent fact-check of
  `/flow:review-pr` ("Step 4.5" there) with it, so the lane matches the
  `/flow:review-pr` `comments` lane.

They run **here**, before the push — not after it. Four of them are also
`/flow:review-pr` lanes: `flow:code-reviewer`, `flow:silent-failure-hunter`,
`flow:comment-analyzer` and `flow:pr-test-analyzer`.

**Do not hand reviewers the plan file's own rationale as if it were
established fact.** The plan file, commit messages, and any in-code comments
written during this session all encode *this session's* belief about why the
implementation is correct — the same belief that produced the code in the
first place. A reviewer agent is launched fresh (no memory of this
conversation), but if its prompt includes "the plan says X should work
because Y," it is reasoning from an assertion, not verifying one, and a wrong
Y will look consistent with the code that was written to satisfy it. Give
each reviewer the diff, the full file contents, and the acceptance
criteria/checklist items as *claims to check*, not as background truth —
phrase the prompt so a query's correctness, a security control's presence, or
a documented failure mode is something the reviewer confirms against the
running code/DB/framework, not something it takes on the plan's word. This is
the same principle `/flow:review-pr` applies to comment fact-checking;
apply it here to every reviewer, not only the ones checking comments.

**Why parallel and why before the push.** Serial reviewers each see a
different artifact, which guarantees that round N+1 finds something round N
never looked at. A PR that is implemented once and reviewed two to four
times produces a commit in each round, and a round can exist only to repair
a defect that the *previous* round's fix introduced. The fix commit is
always the least scrutinised code in the PR.

**Triage every finding once, into three buckets:**

| Bucket | Test | Action |
| --- | --- | --- |
| **Blocking** | Verified, reproducible, and in this diff | Fix now, this PR |
| **Advisory** | Real, but not this issue's job | New issue via `/flow:found` |
| **Note** | Wording, style, docs nuance | Fix only if already on that line |

**Record each finding that you do not fix.** Write one line for it under a
`## Review decisions` heading at the end of the plan file. Create the
heading if it is not there. Use the line forms of `/flow:review-pr`
("Record each decision" there):

```text
- `<file:line>` — <issue> — False positive: <reason>
- `<file:line>` — <suggestion> — Skipped: <reason>
- `<file:line>` — <suggestion> — Deferred: ledger | issue #<n>
```

- **Advisory** — `/flow:found` sends it to a new issue or to the cleanup
  ledger. Write `Deferred: issue #<n>` or `Deferred: ledger`. A hotfix plan
  (Step 6.4) takes no ledger edits. For a hotfix plan: a defect (a user
  or an operator sees a wrong result) becomes a new issue through the
  "Defer" steps of `/flow:found`; cleanup is skipped. Write
  `Deferred: issue #<n>` or `Skipped: <reason>`. If the `ledger` key is
  absent, treat a cleanup finding the same way: write `Skipped: <reason>`.
- **Note** that you do not fix — write `Skipped: <reason>`.
- A finding that is not real (the code, a query, or a test result
  contradicts it) — write `False positive: <reason>`.

`/flow:commit-push-pr` copies this section into the PR body.

Fix all Blocking findings in **one** batch of edits, then re-check **only
the diff of that batch**, with only the reviewers whose findings it addressed. That is
round two, it is cheap, and it is exactly where a self-inflicted regression
would be caught.

**Round two's findings are triaged by a fresh agent, not by this session.**
The reviewer agents that produce round two's findings are already launched
independently, but the *triage* — deciding whether a given finding is
Blocking, Advisory, or a non-issue — is a judgment call, and this session
already has a stake in round one's fix being correct (it just wrote it). Left
to this session, an ambiguous round-two finding is exactly the kind of thing
that gets resolved in favor of "good enough, move on" without anyone
independent weighing in. Launch a fresh `general-purpose` agent (not a fork —
same reasoning as the comment fact-check in `/flow:review-pr`: a fork
inherits this session's belief that the fix worked, which is precisely what
triage needs to not assume) with round two's raw findings, the corrected
diff, and the triage table above; ask it to return the
Blocking/Advisory/Note classification for each finding. Use its
classification, not this session's own read of the findings, to decide
whether round two is clean.

**The two-round ceiling.** If a third round is needed, stop. Three rounds of
fixes on one issue means the plan was wrong, not that the reviewers are
thorough — use AskUserQuestion to re-gate the plan rather than continuing to
patch (the `flow:workflow` skill, `references/review.md`, "Two-round
ceiling"):

- Question: "This is the third review round on #NNN. What's the call?"
- Options: `Re-scope the plan` (recommended — the remaining findings suggest
  the approach, not the code, is the problem), `Split the rest into a
  follow-up issue`, `Keep fixing in this PR` (say why)

Mark the corresponding checklist items `[x]` once the round is clean.

**Record the review fingerprint.** After Step 6.8, only Step 7 fixes edit a
tracked file, and the fingerprint excludes the git-ignored plan file, so a
stamp taken here still matches at hand-off. When the round is clean, run
`flow-review-fingerprint <base-ref>` (the base ref from Step 6.4) and
add one line to the plan file, below the Implementation Checklist:

```text
Review fingerprint: <hash> — clean lanes: code-reviewer, silent-failure-hunter, comment-analyzer, pr-test-analyzer
```

If the script exits 1, it found no base ref or no merge base. Do not record
a fingerprint. Tell the user that no fingerprint was recorded, and why.
`/flow:review-pr` then runs all of its lanes.

The line names only lanes that `/flow:review-pr` maps to an aspect.
Name each one that qualifies, in this order:

| Lane name | Ran in | `/flow:review-pr` aspect |
| --- | --- | --- |
| `code-reviewer` | Step 7 | `code` |
| `silent-failure-hunter` | Step 7 | `errors` |
| `comment-analyzer` | Step 7, with the `/flow:review-pr` comment fact-check | `comments` |
| `pr-test-analyzer` | Step 7 | `tests` |

Name a lane only when its last review saw the diff at this fingerprint and
reported no Blocking finding. A lane that ran only in round one does not
qualify when round two changed files. Do not name a lane that did not run.
Name no other agent. `/flow:review-pr` skips the named lanes when the
branch still has the same fingerprint.

### Step 8: Confirm Plan Completeness

Before moving to hand-off, re-scan the plan file: every checklist item should
now be `[x]` or carry the N/A marker below. If any other item remains `[ ]`,
use AskUserQuestion rather than deciding
yourself — even when it looks like the item turned out to be unnecessary:

- Question: "'`<item>`' is still unchecked. How should I handle it?"
- Options: `Mark N/A with a reason` (only offer this when you can state why
  it turned out unnecessary), `Do the work now`, `Let me look myself first`

Do not silently leave unchecked items with no explanation, and do not
silently mark something N/A on your own judgment — that defeats the purpose
of a plan a later step can trust.

**The N/A marker.** On `Mark N/A with a reason`, leave the item `[ ]` and
add a space, `— N/A: <reason>` at the end of its line. The line then has
this exact form:

```text
- [ ] <item> — N/A: <reason>
```

`/flow:review-pr` and `/flow:commit-push-pr` find N/A items by this form.
Use no other form.

Also check the plan's `## Ledger items` section. Each `- [x]` line must be
fixed in this branch, and its line must be gone from the `ledger` file. If
the line is still in the ledger file, delete it now (Step 5, "Ledger
items"). Mark a ledger item N/A with the same marker, leave it `[ ]`, and
leave its line in the ledger file.

**Stale fingerprint.** If this step changed any tracked file (the work from
`Do the work now`, or a ledger line deleted), delete the plan file's
`Review fingerprint:` line. The Step 7 lanes did not see that change, so
`/flow:review-pr` runs all of its lanes. A change to the plan file alone does
not count: the plan file is git-ignored.

Update the plan file's status line to `**Status:** Implemented — pending
commit/PR`. This is the last edit before hand-off, so a stop after it loses
no work (Step 2 resumes it).

### Step 9: Hand Off

**Do NOT commit, push, or create PRs.** State plainly that implementation is
complete and the plan file at `<plans>/issues/issue-<NUMBER>-<slug>.md`
shows every item verified complete.

Then tell the user, as plain text: "The plan file holds the state, so you
may run `/clear` now. Then type `/commit`, then `/flow:review-pr`." Do not
offer a menu. Do not start `/commit` through the Skill tool: `/commit` is the
plugin skill `commit-commands:commit`, which declares no `model:`, so the
two commands are not a same-model pair (the `flow:workflow` skill,
`SKILL.md`, "Hand-offs between commands"). The plugin `/commit` names no
next step, so this text must name `/flow:review-pr`.

`/flow:review-pr` must run after `/commit`, not before. It reviews only
committed history, so it stops when the working tree has uncommitted
changes. It skips the lanes that the Step 7 fingerprint names, and
stamps the fingerprint again when its own run is clean.
`/flow:review-pr` then hands off to `/flow:commit-push-pr` as plain text.

**For bug-fix plans** (plan file has a Bug Escape Analysis section), remind
the user to include the escape analysis in the PR description.

**Delete the plan file** once the user confirms the PR is merged and the
issue is closed (typically during/after `/flow:finish-issue`) — its job (a
verifiable record other agents/sessions could check against) is done once
the code is merged; the merged diff and closed issue are then the source of
truth. The `plans` folder is git-ignored,
so that deletion is a plain `rm` with no git operation. Do not delete it from
within this command — that happens later, at merge time, not here.

## Available Agents

| Agent | `subagent_type` | Model | Use When |
| --- | --- | --- | --- |
| Software Developer | `flow:software-developer` | `sonnet` (Small), `opus` (Medium/Large) | **Primary coding agent** |
| Senior Architect | `flow:senior-architect` | agent default (`sonnet`); `opus` for Large | Post-implementation review |
| Senior Test Engineer | `flow:senior-test-engineer` | `sonnet` | Writing/running tests from the plan |
| Technical Documentation Writer | `flow:technical-documentation-writer` | `haiku` | Docs updates from the plan |
| Security Reviewer | `flow:security-reviewer` | (per agent default) | Step 7, security review |
| Silent Failure Hunter | `flow:silent-failure-hunter` | (per agent default) | Step 7, only when a new structured-input method or new/modified database query was added |
| Comment Analyzer | `flow:comment-analyzer` | (per agent default) | Step 7, only when comments or doc blocks changed |

## Critical Rules

- **NEVER implement against an unapproved plan** — Step 2 is a hard gate.
- **NEVER commit, push, or create PRs** — hand off at Step 9, always.
- **Re-verify before trusting the checklist** — Step 3 runs every time this
  command starts, even on a plan that looks fully checked-off already. A
  stale or falsely-checked item is worse than a slow verification pass.
- **Update the plan file incrementally, not in one batch at the end** — mark
  each item `[x]` as its agent completes, so the file is always an accurate
  snapshot if this command is interrupted or resumed by another session.
- **Respect the plan's parallel-safety annotations** — don't parallelize an
  item the plan marked as dependent, and don't invent parallelism for
  unannotated items.
- **Surface discrepancies, never silently resolve them** — a checked item
  that isn't actually in the repo, or unchecked items with no remaining work,
  both get raised to the user via AskUserQuestion (Steps 3 and 8), never
  decided unilaterally.
- **Never assume — verify via code or ask.** Objective facts about the repo
  (does the file exist, does the test pass, is this function already
  implemented) get checked directly — grep/read/run it, don't guess and
  don't ask the user something you can verify yourself. Judgment calls
  (resolve this discrepancy which way, is this item really unnecessary) go
  to AskUserQuestion. Never present a checklist item as done, or a plan as
  complete, without having done one of the two.
- **Use AskUserQuestion for every discrepancy and completeness gap**
  (Steps 3, 8) — not free-form chat questions. The hand-off (Step 9) is
  plain text, never a menu.
- **Follow project conventions** from CLAUDE.md, the `standards` files, and
  the project's `.claude/rules/`.
- **Execute risky code paths, don't just read them** — new/changed database
  queries against a real local DB, and wrong-typed (not just missing)
  structured-input tests for new public methods. Both classes ship real,
  review-missed bugs from careful-looking code that only breaks at
  execution time. Catch them in Step 6, not two workflow stages later at
  `/flow:review-pr`.
- **Check the cleanup ledger for touched files, offer to fix, never fix
  unconditionally and never silently skip** (Step 6.6) — a file this plan
  ends up touching may carry an open ledger item the plan never saw. Ask the
  user per item; act on their answer.
- **A fixed ledger item leaves the ledger in the same branch** — delete its
  line from the `ledger` file (Step 5, "Ledger items").
- **Never absorb a deviation** — a change the plan did not approve stops
  the work and goes back to the plan gate (Step 5, "Deviation rule").

## Report

End with this list:

```markdown
Skipped steps:
- <step>: <reason>, for example "release notes: no key in .claude/project.md"
```

Write "Skipped steps: none" when no step skipped. Then state the next
command (`/commit`, then `/flow:review-pr`) and the hand-off rule from the
`flow:workflow` skill, `SKILL.md`, "Hand-offs between commands".
