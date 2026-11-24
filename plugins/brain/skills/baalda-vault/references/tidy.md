# Tidy: weekly clean-up of UniBrain

Use these steps when Jim says "tidy" or "clean up the vault", or types
`/tidy` in Claude Code. Do a tidy once a week. Wrap adds to the vault, and
tidy keeps the notes small enough to read.

## Rules

1. Move, do not delete. Old text goes to `Archive/`. Ask Jim before you
   delete a note.
2. Read a note before you write it. Pass its `revision` as
   `expectedRevision`.
3. Copy text word for word when you move it. Do not summarize text that
   you move to `Archive/`.
4. Do not change a State in `Projects/In progress.md` without Jim's word.

## Steps

1. Read the root `AGENTS.md` and `Archive/AGENTS.md`.
2. **Open questions.** In `Inbox/Open questions.md`:
   1. Move each checked line whose answer date is more than 14 days old to
      `Archive/Open questions answered <YYYY>.md`, under the same heading.
      Create the note if it does not exist, and add it to
      `Archive/AGENTS.md`.
   2. Make a list of the open lines that are more than 30 days old. Ask
      Jim for each line: keep, answer, or drop. Move a dropped line to the
      archive note with `Dropped <date>`.
3. **Work in progress.** In `Projects/In progress.md`, make a list of the
   rows whose Updated date is more than 7 days old. Ask Jim which to set to
   `waiting` or `paused`, and which ended.
4. **Finished prompts.** Find each resume prompt outside `Archive/` with
   `status: done` or `status: closed`. Move it to `Archive/Resume prompts/`.
   Update the index of the old folder and of
   `Archive/Resume prompts/AGENTS.md`.
5. **Hub logs.** For each hub note of more than 40 KB:
   1. Move the log lines that are more than 30 days old to
      `Archive/<Hub> log <YYYY>.md`. Append them in date order.
   2. In the hub, add one line where the moved lines were:
      `Older log lines: [[<Hub> log <YYYY>]]`.
   3. Keep the status lines and the open questions in the hub.
6. **Daily index.** In `Daily/AGENTS.md`:
   1. Shorten each summary of more than 200 characters. Keep the hub links
      and the main outcome from the daily note.
   2. If the table has more than 60 rows, move the rows of earlier months
      to `Archive/Daily index <YYYY-MM>.md`.
7. **Indexes.** For each folder `AGENTS.md`, compare the table with the
   notes in the folder (`list_notes` with the folder path). Add a row for
   each note with no row. Remove each row whose note does not exist. Tell
   Jim each change.
8. **Inbox.** List the notes in `Inbox/` that are more than 7 days old,
   except `Open questions.md` and `AGENTS.md`. Ask Jim where each one
   goes.
9. Append one section to today's daily note: `## Vault tidy`. Write the
   counts: lines moved, prompts archived, logs trimmed, index rows fixed.
10. Tell Jim each note that you created, changed, or moved, with its path.
