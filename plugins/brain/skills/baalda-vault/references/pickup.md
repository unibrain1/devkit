# Pick up: start a session from UniBrain

Use these steps when Jim says "pick up <activity>" or "resume <activity>",
or types `/pickup` in Claude Code. A step marked **Claude Code** applies only
when you can run shell commands. Skip it in the desktop and phone apps.

## Rules

1. The repo is the source of truth for code facts. If the vault and the
   repo do not agree, believe the repo and tell Jim.
2. The resume prompt holds the approvals and the stop rules for the work.
   Obey them.

## Steps

1. Read the root `AGENTS.md` and `Projects/In progress.md`.
2. Find the activity row:
   1. If Jim named an activity, find the row whose Activity or Project
      matches it. If exactly one row matches, use it. Go to step 3.
   2. **Claude Code.** If no row or more than one row matches, find the
      rows for the current repo. Run `git remote get-url origin`. A row is
      for the current repo if the `repo:` key of its hub names the same
      GitHub repo.
   3. Ask Jim to select a row. Show at most 4 rows with State `active` or
      `waiting`: the current-repo rows first, then `active`, then
      `waiting`. Mark one row as recommended. Name the other rows in the
      question text.
   4. If no row matches, search the vault for the hub. Tell Jim that no
      resume prompt exists. Stop.
3. Read the note in the Prompt note column. If the Resume prompt cell names
   a section, read that section.
4. Read the hub: the status lines and the last 10 log lines.
5. Find the newest daily section for the hub. Read the daily notes from the
   row's Updated date to today, newest first, or search for `[[<Hub>]]`.
   Read the newest section for the activity.
6. Read `Inbox/Open questions.md`. List the open lines that link to the hub
   or to the resume prompt.
7. If the row's Updated date is more than 7 days old, tell Jim. Offer to
   set the State to `waiting`.
8. **Claude Code.** Check the repo:
   1. If the current directory is not the project's repo, tell Jim the
      repo path. Ask whether to continue here.
   2. Run `git status -sb`, `git log --oneline -5`, and
      `gh pr list --author @me`.
   3. Compare the result with the Stage and Next step of the row. Tell Jim
      each difference.
9. Give Jim a brief of six lines or fewer: the activity, the stage, the
   next step, each difference from step 8, the open questions from step 6,
   and the first question of the resume prompt.
10. Follow the resume prompt. If it says to ask Jim first, ask and wait.
    Outside Claude Code, if the work needs code changes, tell Jim to start
    it in Claude Code in the project's repo.
11. When the session ends, do the wrap steps (`references/wrap.md`).
