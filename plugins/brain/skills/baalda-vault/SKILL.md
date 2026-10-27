---
name: baalda-vault
description: Rules for Jim's second brain, the Baalda vault "UniBrain". Use this skill every time you use the Baalda connector or tools, and when Jim says "my second brain", "my vault", "my brain", "my inbox", "add to my notes", "remember this in Baalda", "daily note", "wrap", "wrap up", "end the session", "pick up" followed by an activity name, or asks about the status of one of his projects.
---

# Baalda vault: UniBrain

UniBrain is Jim's second brain. It is a Baalda vault of Markdown notes. People and AI assistants read and edit it together.

## Before you write

1. Read the vault root `AGENTS.md`. It has the routing table and the vault rules.
2. Read the `AGENTS.md` of the folder that you will write to.
3. Search before you create a note. If a note fits, update it. Do not create a duplicate.

## Where notes go

| What it is | Folder |
|---|---|
| A quick idea or a capture with no home | `Inbox/` |
| A log for one day | `Daily/YYYY-MM-DD` (today's real date) |
| Work with an end point | `Projects/<Project>/`. The hub note has the same name as the folder. |
| An ongoing responsibility | `Areas/` |
| Reusable reference knowledge | `Resources/` |
| A person or organization | `People/` |
| A weekly or milestone review | `Reviews/` |
| Finished work | `Archive/` |

## Sensitive folders

Do not read or search `Areas/Health/` or `Areas/Personal/` unless Jim asks for it in this chat. Do not copy their content into other notes.

## How to edit

1. Change only the part of a note that you mean to change. Do not rewrite a whole note to fix one line.
2. To add to a log or a list, append. Do not replace earlier entries.
3. When you add, rename, move, or delete a note, update the folder's `AGENTS.md` table in the same change.
4. Do not invent a number, date, name, or quote. If a fact is not known, write `unknown`.
5. A project's GitHub repo is the source of truth for code facts. Do not copy a README into the vault.

## Session end: "wrap"

When Jim says "wrap", "wrap up", or "end the session", do these steps. Claude Code has the same steps as the `/wrap` command.

1. Read `Daily/AGENTS.md` and `Projects/In progress.md`.
2. Use today's real date. If `Daily/YYYY-MM-DD` does not exist, create it and add a row to the `Daily/AGENTS.md` table.
3. Append one section for each project to the daily note: `## [[<Project hub>]] (session end)`. Write what was done, the decisions, and the next step.
4. Update the status and the log of each project hub that the chat changed.
5. If the work continues in a later session, write or update its resume prompt in the project folder. Then update its row in `Projects/In progress.md`, and copy the rows to `DATA.inProgress` in `Dashboards/Home.html`.
6. For each fact that you wrote as `unknown` and that only Jim knows, append a line to `Inbox/Open questions.md`.
7. If the chat did no work worth a record, tell Jim. Write nothing.

## Session start: "pick up"

When Jim says "pick up <activity>" or "resume <activity>", do these steps. Claude Code has the same steps as the `/pickup` command.

1. Read `Projects/In progress.md`. Find the row for the activity. If no row or more than one row matches, show the rows and ask Jim.
2. Read the resume prompt note in the Prompt note column, and the section that the row names.
3. Read the project hub and the last daily note section for the project.
4. Give Jim a brief of five lines or fewer: the stage, the next step, and the first question.
5. Follow the resume prompt. If the work needs code changes, tell Jim to start it in Claude Code in the project's repo.

## When you finish

Tell Jim which notes you created or changed, with their paths.
