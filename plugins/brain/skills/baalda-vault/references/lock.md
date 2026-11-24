# Lock: one writer at a time in UniBrain

Wrap and tidy write to many notes. If two sessions run them at the same
time, both can append the same text to a note, and both do the same work.
The lock note lets only one session do these writes at a time.

`wrap.md` and `tidy.md` get the lock before the first write and release it
at the end. `pickup.md` gets the lock only for its one write.

## The lock note

- Path: `Vault lock.md` at the vault root.
- The body has one lock line. The line is `free`, or
  `held by <name> <id> for <command> since <time>`.
- `<name>`: the Claude Code session name if you know it. If not, the name
  of the repo folder. In the desktop and phone apps, use `claude.ai`.
- `<id>`: 4 random hex characters, for example `a3f9`. Make the id once,
  before you first get the lock. Use the same id until the command ends.
  Two sessions can have the same name, but they do not have the same id.
- `<command>`: `wrap`, `tidy`, or `pickup`, then the activity name if
  there is one.
- `<time>`: the current UTC time, in the format `2026-11-24T18:40Z`.
- A lock is stale when its time is more than 15 minutes ago.

## Get the lock

1. Read `Vault lock.md`. Keep its `revision`.
2. If the note does not exist, create it with the body `free`. If Baalda
   refuses the create because the note exists, another session created it
   first. In both cases, do step 1 again.
3. If the lock line is `free`, or the lock is stale, go to step 5.
4. If the lock line has this session's name and id, go to step 5. Otherwise another
   session holds the lock:
   1. Tell Jim the name, the command, and the time from the lock line.
   2. Do not write to the vault.
   3. Ask Jim: wait and try again, or stop. If Jim says wait, wait about
      one minute. Then do step 1 again.
5. Replace the lock line with
   `held by <name> <id> for <command> since <time>`.
   Use `edit_note` with `expectedRevision` from step 1.
6. If Baalda refuses the edit because the revision changed, another session
   changed the note first. Do step 1 again.
7. If the edit succeeds, you hold the lock.

## While you hold the lock

1. Before you ask Jim a question and wait for the answer, release the lock.
   After the answer, get the lock again.
2. If you write for more than 10 minutes, replace the time in the lock line
   with the current time.

## Release the lock

1. Read `Vault lock.md`.
2. If the lock line has this session's name and id, replace it with
   `free`. Use
   `edit_note` with `expectedRevision`.
3. If the lock line has another name or id, do not change it. That session
   took a stale lock.
4. Release the lock also when a step fails or Jim stops the command.
