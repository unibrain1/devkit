---
name: baalda-vault
description: Rules for Jim's second brain, the Baalda vault "UniBrain". Use this skill every time you use the Baalda connector or tools, and when Jim says "my second brain", "my vault", "my brain", "my inbox", "add to my notes", "remember this in Baalda", "daily note", or asks about the status of one of his projects.
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

## When you finish

Tell Jim which notes you created or changed, with their paths.
