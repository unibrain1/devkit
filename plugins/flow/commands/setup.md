---
description: Set up this repo for the flow commands. Creates .claude/project.md and adds or updates the flow block in CLAUDE.md.
argument-hint: "[--check]"
---

# Set up flow in this repo

A plugin has no install step, so this command does the job. Run it one time
in each repo, and again when the SessionStart check says "Run /flow:setup".

With `--check`, do Step 1 and Step 2 only. Report the state. Change nothing.

## Hard constraints

1. Do not write a file or create a label before the user approves the exact
   content, diff, or list.
2. Do not change text in CLAUDE.md outside the flow markers.
3. Do not commit, push, or make a branch. The user decides how to commit.

## Step 1: Check the repo

1. Run `git rev-parse --show-toplevel`. If it fails, tell the user that
   flow needs a git repo. Stop.
2. Run `git status --short`. If there are changes to `CLAUDE.md` or
   `.claude/project.md`, tell the user. Ask if you can continue.

## Step 2: Read the current state

1. Run `flow-project-fact --file`. Then check if that file exists.
2. If it exists, run `flow-project-check`. Keep its output for the report.
3. Run `flow-claude-block --status`. Keep the output.
4. Run `flow-labels --missing`. Keep the list of missing labels.

If `$ARGUMENTS` has `--check`, report the four results and stop.

## Step 3: Create `.claude/project.md`

Do this step only if the file does not exist.

1. Find the likely `test` and `lint` commands. Read only the files that
   exist: `package.json` (scripts), `composer.json` (scripts), `Makefile`,
   `pyproject.toml`, `justfile`, `Taskfile.yml`, and the project's CLAUDE.md.
2. Show the user your proposal for each of the two keys, with the file that
   it came from. Ask the user to confirm or change each value.
3. Read the template at `${CLAUDE_PLUGIN_ROOT}/templates/project.md`.
   Replace `{{test}}` and `{{lint}}` with the confirmed values.
4. Tell the user about the optional keys. Give the link
   <https://github.com/unibrain1/devkit/blob/main/docs/project-md.md>.
   Recommend `plans` and `release_notes`: the issue and milestone commands
   stop without them. Propose `plans` as a git-ignored folder, and check
   that `.gitignore` covers it. Ask if the user wants to add a key now. Add
   only keys that the user gives.
5. Show the full file content. Write it only after the user approves.
6. Run `flow-project-check`. If it fails, show the error and fix the file
   with the user.

## Step 4: Add or update the CLAUDE.md block

Do this step only if Step 2 did not report `current`.

1. Run `flow-claude-block --diff`. Show the full diff to the user.
2. Tell the user what the block does: it gives every session the branch
   model, the command order, and the hand-off rule. The full method stays
   in the `flow:workflow` skill.
3. If CLAUDE.md has its own section with the same topic (for example a
   "Developer Workflow" section), name it. Recommend that the user deletes
   it after the block is in place. Do not delete it yourself.
4. Ask for approval. If the user approves, run `flow-claude-block --apply`.
   If not, skip this step.

## Step 5: Create the missing labels

Do this step only if Step 2 found missing labels.

1. Show the missing labels as a table: name, color, description.
2. Tell the user that the flow commands use these labels, and that this
   step never changes a label that exists.
3. Ask for approval. If the user approves, run `flow-labels --create`.
   If not, skip this step.

## Step 6: Report

Print a short report:

- `.claude/project.md`: created, already present, or skipped.
- `flow-project-check`: passed, or the errors.
- CLAUDE.md block: added, updated from rev N, already current, or skipped.
- Labels: created (with the count), none missing, or skipped.
- Skipped steps: each step that you skipped, with the reason.
- Next: tell the user to review the changes with `git diff` and to commit
  them.
