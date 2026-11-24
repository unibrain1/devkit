# Wrap: record the session in UniBrain

Use these steps when Jim says "wrap", "wrap up", or "end the session", or
types `/wrap` in Claude Code. A step marked **Claude Code** applies only when
you can run shell commands. Skip it in the desktop and phone apps.

## Rules

1. Write only through the Baalda tools.
2. Read a note before you write it. Pass its `revision` as
   `expectedRevision`.
3. Use `edit_note` or `append_note`. Do not rewrite a whole note.
4. When you retry an `append_note`, use the same `idempotencyKey`.
5. Do not invent a number, date, name, PR number, or commit hash. If a fact
   is not known, write `unknown`.
6. Do not commit, push, or merge in a repo. Wrap writes to the vault only.
7. If the session did no work worth a record, tell Jim. Write nothing.
8. Hold the vault lock for all writes. Follow `references/lock.md`.

## Steps

0. **Lock.** If the session did no work worth a record, do rule 7 and
   stop. Do not get the lock. Otherwise, get the vault lock
   (`references/lock.md`, "Get the lock"). Use the command `wrap` and the
   activity name.
1. Read the root `AGENTS.md`, `Daily/AGENTS.md`, and
   `Projects/In progress.md`.
2. Make a list of the hubs that the session changed. A hub is a project hub
   in `Projects/` or an Area hub, for example `[[Home Assistant]]`.
3. **Claude Code.** For each repo that the session changed, collect the
   facts:
   1. Run `git log --oneline --since=midnight`.
   2. Run `gh pr list --state merged --search "merged:>=<today>"` and
      `gh pr list --author @me`.
   3. Record what merged, what is open, and what is deployed. If the deploy
      state is not known, write `unknown`.
4. **Daily note.** Use today's real date.
   1. If `Daily/<YYYY-MM-DD>` does not exist, create it with the frontmatter
      of the earlier daily notes.
   2. For each hub, look for a section of today for the same activity. If
      one exists, edit that section. Do not add a second section for the
      same activity on the same day.
   3. If no section exists, append
      `## [[<Hub>]] <activity> (session end)`.
   4. Write at most 10 bullets: what was done, what merged or deployed (PR
      numbers, short commit hashes), Jim's decisions, and the next step.
5. **Daily index.** `Daily/AGENTS.md` has one row for each day.
   1. If today's row exists, edit it. If not, add it.
   2. Keep the summary at 200 characters or fewer: the hubs touched as
      links, then the main outcome. The detail stays in the daily note.
6. **Hub.** In each hub that the session changed, update the status lines.
   Add one dated log line for each decision. Update the open questions.
7. **Work in progress.** For each activity of the session:
   1. If the work continues, write or update its resume prompt in the
      hub's folder. Include what to read first, the current state, the
      approvals, the next steps, and the rules. Then update its row in
      `Projects/In progress.md`: State, Stage, Next step, Waiting on,
      Resume prompt, Prompt note, Updated.
   2. If the work started in this session, add a row.
   3. If Jim says that the work ended, delete its row. Do not decide this
      yourself: ask Jim if it is not clear. Add a log line to the hub. Set
      the prompt's `status: done`. Move the prompt to
      `Archive/Resume prompts/`. Update the index of the old folder and of
      `Archive/Resume prompts/AGENTS.md`.
   4. The dashboard reads `Projects/In progress.md` live. Do not copy rows
      into `Dashboards/Home.html`.
8. **Open questions.** In `Inbox/Open questions.md`:
   1. Append one line for each fact that you wrote as `unknown` and that
      only Jim knows. Use the format
      `- [ ] <question> (asked <date>) → [[<Note>]]`.
   2. Find the open lines that link to a hub of this session. If the
      session answered one, write the answer in the note that owns the
      fact. Then check the line and add `Answered <date>: <answer>`.
   3. Never check a line without an answer.
9. **Lessons.** Do this step only if the session made a rule that applies
   to more than one project. Search `Resources/AI & Claude/`. Update a
   note that fits, or create one. Update its `AGENTS.md`.
10. **Inbox.** Do this step only if the session had an idea with no home.
    Put it in `Inbox/` and update `Inbox/AGENTS.md`.
11. **Check.** Read each note that you wrote again. Make sure that each new
    section, row, and line is there. If one is missing, write it again,
    then read again. If it is still missing, tell Jim which write failed.
12. **Lock.** Release the vault lock (`references/lock.md`, "Release the
    lock").
13. Tell Jim each note that you created or changed, with its path. Give the
    next step in one line.
