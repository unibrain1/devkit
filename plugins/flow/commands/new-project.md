---
description: Make a new repo from a family template. Asks the setup questions, recommends a family, creates the GitHub repo, and makes the first commit.
argument-hint: "[name]"
---

# Make a new project from a family template

Run this command in an empty folder. It makes a new repo from one family
template in `${CLAUDE_PLUGIN_ROOT}/templates/`. The family rules are in
<https://github.com/unibrain1/devkit/blob/main/docs/families.md>. This
text holds each fact that the command needs.

For a repo that has files, use `/flow:setup`.

## Before you start

The flow plugin must load in the empty folder. The folder has no
`.claude/settings.json`, so the session does not enable flow. Start the
session with the marketplace copy of flow. Each machine that has the
devkit marketplace has this copy:

```sh
claude --plugin-dir ~/.claude/plugins/marketplaces/devkit/plugins/flow
```

If `$CLAUDE_CONFIG_DIR` is set, the marketplace copy is in
`$CLAUDE_CONFIG_DIR/plugins/marketplaces/devkit/plugins/flow`. Use that
path in place of `~/.claude`.

## Hard constraints

1. Do not write a file before the user approves the exact command, edit, or
   content.
2. Do not create the GitHub repo before the user approves the exact
   command.
3. Do not create a label, install a plugin, commit, or push before the user
   approves the exact command or list.
4. Never use `--force` or `--no-verify`.
5. If a step fails and this text gives no other instruction, show the
   output and stop.

## Step 1: Check the folder

1. Run `ls -A`. The folder must be empty, or hold only `.git`, a
   `.DS_Store` file, or the two. Finder makes the `.DS_Store` file.
2. If `.git` exists, run `git rev-parse --show-toplevel`. It must print
   this folder.
3. If `.git` exists, run `git rev-parse --verify -q HEAD`. It must fail.
   A repo with a commit is not empty.
4. If `.git` exists, run `git remote`. It must print nothing.
5. If `.git` does not exist, run `git rev-parse --show-toplevel`. It must
   fail. A folder in another repo is not a new repo.
6. Run `gh auth status`. It must exit 0.

If a check fails, tell the user which check failed. Tell the user to use
`/flow:setup` for a repo with files. Stop.

## Step 2: Ask the setup questions

Ask these decisions in rounds, as the `flow:workflow` skill,
`references/review.md`, "Decision rounds", says. Put one decision in each
question, and at most 4 questions in one AskUserQuestion call. Send the
next call directly after the answers come back.
Do no other work between the calls.
Act on the answers only after the last call.

1. Kind: `Static site`, `Web app`, `Container app`, `iOS app`. The user
   gives "other" with the `Other` option. A web app is an app with a
   database or a release version.
2. Container image: `No`, `Yes`. Yes means that CI builds an image and
   pushes it to GHCR.
3. Deploy target: `Cloudflare Pages`, `A host with a webhook or PHP`,
   `A2 Hosting with a deploy remote`, `A container host that pulls from
   GHCR`.
4. Visibility: `Private`, `Public`.
5. Outside contributors: `No`, `Yes`.
6. Database: `No`, `Yes`.
7. Secrets (API keys or passwords in `.env` files): `No`, `Yes`.
8. Name: the GitHub repo name. Offer the folder name and, if
   `$ARGUMENTS` has a name, that name.
9. Description: one sentence about the project. Draft 2 candidates from
   the conversation.

Put the recommended option first, with `(Recommended)` in its label. Its
description gives the reason. Base each recommendation on what the user
said in the conversation. If the conversation gives no reason, recommend
`Private` and `No` for each yes-or-no question. The user can type an
answer with `Other`. A note on an answer is part of the answer.

The name must hold only letters, digits, `-`, `_`, and `.`. If it does
not, tell the user. Ask the name question again.

## Step 3: Recommend the family

Find the family with this rule. The first match wins:

1. An iOS app: `ios-app`.
2. A container image: `container-ghcr`.
3. A web app with a database or a version: `web-app`.
4. A static site on Cloudflare Pages: `static-site-cloudflare`.
5. A static site on a host with a webhook or PHP: `static-site-host`.
6. Other: `other`. The repo gets the baseline, the starter
   `.claude/settings.json`, a `.gitignore` for `.env` files and
   `docs/plans/`, and `.claude/project.md`.

Ask the user to confirm the family in one AskUserQuestion call, as the
`flow:workflow` skill, `references/review.md`, "Decision rounds", says.
The call has one question (at most 4 questions in one call). Put the
family from the rule first, with `(Recommended)` in its label. Its
description gives the rule line that matched. Add up to 3 other families
that are near the answers. Act on the answer only after the call.

Use the confirmed family in each later step.

## Step 4: Ask the family questions

Do this step only for `web-app`, `container-ghcr`, and `ios-app`.

Ask these decisions in rounds, as the `flow:workflow` skill,
`references/review.md`, "Decision rounds", says. Put one decision in each
question, and at most 4 questions in one AskUserQuestion call. Send the
next call directly after the answers come back.
Do no other work between the calls.
Act on the answers only after the last call.

For `web-app`:

1. Stack: `Node and npm`, `PHP and Composer`. The Dependabot ecosystem is
   `npm` or `composer`.
2. Host: `cloudflare-pages`, `a2-tag`. Ask this question only if the
   deploy target is not Cloudflare Pages or A2 Hosting. Otherwise, use
   `cloudflare-pages` for Cloudflare Pages and `a2-tag` for A2 Hosting.
3. Version form: `npm` (`package.json` holds the version), `VERSION file`
   (for another stack).
4. Type check: `Yes`, `No`.
5. Fast tests (a quick test command for each commit): `Yes`, `No`.

For `container-ghcr`:

1. Stack ecosystem for Dependabot: `npm`, `pip`, `gomod`. The user can
   type another ecosystem with `Other`.
2. Fast tests (a quick test command for each commit): `Yes`, `No`.

For `ios-app`:

1. Xcode file: `Project (.xcodeproj)`, `Workspace (.xcworkspace)`.
2. Swift package (the app uses a Swift package): `Yes`, `No`.
3. Simulator device. Before you ask, run
   `xcrun simctl list devices available`. Offer up to 4 iPhone names from
   its output. If the command fails, offer one iPhone name. The user can
   type a name with `Other`.

Put the recommended option first, with `(Recommended)` in its label. Its
description gives the reason. A note on an answer is part of the answer.

## Step 5: Ask the commands

Do this step only for `web-app`, `container-ghcr`, `ios-app`, and
`other`.

Ask these decisions in rounds, as the `flow:workflow` skill,
`references/review.md`, "Decision rounds", says. Put one decision in each
question, and at most 4 questions in one AskUserQuestion call. Send the
next call directly after the answers come back.
Do no other work between the calls.
Act on the answers only after the last call.

For each question, draft 2 or 3 candidate values from the stack and the
other answers. Put the recommended candidate first, with `(Recommended)`
in its label. Its description gives the reason. The user can type a value
with `Other`.

- `web-app`: `test` (all the tests), `test_quick` (only if fast tests is
  `Yes`), `typecheck` (only if type check is `Yes`), `lint` (the lint
  command with no type check), and `verify` (the full check before a
  release).
- `container-ghcr`: `test`, `test_quick` (only if fast tests is `Yes`),
  and `lint`.
- `ios-app`: the Xcode file name (for example `<App>.xcodeproj`) and the
  scheme. Offer names from the app name.
- `other`: `test` and `lint`.

Refuse a value that holds `${{`, `{{`, or a newline. A GitHub expression in
a `run:` value can inject code. Tell the user why. Ask that question again.

Refuse a `test`, `test_quick`, `typecheck`, `lint`, `verify`,
`milestone_setup`, or `release_checks` value that has a backtick.
`.claude/project.md` holds the value in backticks, so a flow command would
run a shorter command than CI runs. Tell the user why. Ask that question
again.

Refuse a `test`, `test_quick`, `typecheck`, `lint`, or `verify` value that
has `*` at any position. The template makes the allow rule
`Bash(<value>)` from the value. Claude Code reads a `*` at any position in
an allow rule as a wildcard. An allow rule with `*` lets Claude run other
commands with no approval. Tell the user why. Ask that question again.

Refuse an empty `test`, `test_quick`, `typecheck`, `lint`, or `verify`
value. The allow rule `Bash()` could allow all commands. Tell the user
why. Ask that question again.

Refuse a `test`, `test_quick`, `typecheck`, `lint`, or `verify` value that
starts or ends with a space or tab. The allow rule then does not match the
command. Tell the user why. Ask that question again.

For `ios-app`, make the `test` value with this form:

```sh
xcodebuild test -project "<App>.xcodeproj" -scheme "<Scheme>" -destination "platform=iOS Simulator,name=<device>"
```

For a workspace, use `-workspace "<App>.xcworkspace"` in place of
`-project`. If the command pipes the output to a formatter, start it with
`set -o pipefail;`.

## Step 6: Create the GitHub repo

1. Make the two commands. Use `--private` or `--public` from the
   visibility answer. If `.git` does not exist, the commands are:

   ```text
   git init -b main
   gh repo create <name> <--private or --public> --source .
   ```

   If `.git` exists, the commands are:

   ```text
   git symbolic-ref HEAD refs/heads/main
   gh repo create <name> <--private or --public> --source .
   ```

   `git init -b main` does not change the branch of a repo that exists.
   Then HEAD can stay `master`, and the push to `main` in Step 15 fails.
2. Show the two commands from item 1 to the user.
3. Tell the user that `gh repo create` makes the repo on GitHub and adds
   the `origin` remote. It does not push.
4. Ask for approval. If the user does not approve, stop.
5. If the user approves, run the commands from item 1, in that order.
   Use the exact commands that item 2 showed.
6. If a command fails, show the output. Stop.

## Step 7: Copy the template files

1. Make the `flow-template --apply` command. Put each value in a
   `key=value` argument. Quote each argument as one shell word. In a
   single-quoted word, write each `'` as `'\''`.
   - `static-site-cloudflare` and `static-site-host`: `site_name` (the
     name), `site_description` (the description), and `package_name` (the
     name in lowercase, with no spaces).
   - `web-app`: `--host <host>`, `app_name`, `app_description`, `test`,
     `test_quick`, `typecheck`, `lint`, `verify`, `milestone_setup`, and
     `release_checks`. Do not give `test_quick` if fast tests is `No`.
     Do not give `typecheck` if type check is `No`. Step 8 removes those
     placeholders.
   - `container-ghcr`: `app_name`, `app_description`, `test`,
     `test_quick`, `lint`, and `stack_ecosystem`. Do not give `test_quick`
     if fast tests is `No`.
   - `ios-app`: `app_name`, `app_description`, and `test`.
   - `other`: no value. The family folder gives the starter
     `.claude/settings.json`, which enables flow, and a `.gitignore` for
     `.env` files and `docs/plans/`.
2. For `web-app`, the version form gives `milestone_setup` and
   `release_checks`. For the npm form:

   ```text
   milestone_setup: npm version "$(git branch --show-current | sed 's#^milestone/v##')" --no-git-tag-version --allow-same-version
   release_checks: test "milestone/v$(jq -r .version package.json)" = "$(git branch --show-current)" || { echo "package.json version does not match the milestone branch" >&2; exit 1; }
   ```

   For the VERSION file form:

   ```text
   milestone_setup: git branch --show-current | sed 's#^milestone/v##' > VERSION
   release_checks: test "milestone/v$(cat VERSION)" = "$(git branch --show-current)" || { echo "VERSION does not match the milestone branch" >&2; exit 1; }
   ```

3. Show the full command, for example:

   ```text
   flow-template --apply <family> [--host <host>] key=value ...
   ```

4. For `other`, also show the content of `.claude/project.md`. Read the
   template at `${CLAUDE_PLUGIN_ROOT}/templates/project.md`. Replace
   `{{test}}` and `{{lint}}` with the answers.
5. Ask for approval. If the user does not approve, stop.
6. If the user approves, run the command.
   - Exit 0: done.
   - Exit 1: the script refused and wrote no file. Show its output. Stop.
   - Exit 2: a usage error. Show its output. Stop.
   - Exit 3: a partial write. Show its output. Read the `Wrote:` list in
     stderr. Tell the user which files exist. Exit 3 also means that temp
     files (`.flow-template.*`) stay in the repo. Then stderr names them.
     Tell the user to remove them. Stop.
   - Any other exit code is an error. Show the output. Stop.
7. For `other`, write `.claude/project.md` with the approved content.
   Then run `flow-project-check`. If it fails, show the error and fix the
   file with the user.

When this command stops after Step 6, tell the user that the GitHub repo
exists and has no commit.

## Step 8: Make the family edits

Do this step only for `web-app`, `container-ghcr`, and `ios-app`. Show each
edit as a diff. Ask for approval. If the user approves, make the edits with
the Edit tool. In a YAML or JSON string, put `\` before each `\` and `"`.

For `web-app`:

1. If type check is `No`: remove the `typecheck` hook from
   `.pre-commit-config.yaml`. Remove the `{{typecheck}} &&` prefix and
   the space after it from the `lint` key in `.claude/project.md`. Remove
   the `{{typecheck}}` row from the command table in `CLAUDE.md`.
2. If type check is `Yes`: in `.github/workflows/ci.yml`, set the `Lint`
   step to `run: "<typecheck> && <lint>"`. CI has no other type check
   step.
3. If fast tests is `No`: remove the `test-quick` hook from
   `.pre-commit-config.yaml`. Remove the `test_quick` key from
   `.claude/project.md`. Remove the `{{test_quick}}` row from the command
   table in `CLAUDE.md`.
4. Add the stack entry to the end of `.github/dependabot.yml`. Use `npm`
   or `composer` for `<ecosystem>`:

   ```yaml
     - package-ecosystem: <ecosystem>
       directory: /
       schedule:
         interval: weekly
       commit-message:
         prefix: chore(deps)
       groups:
         <ecosystem>:
           patterns: ["*"]
   ```

5. Add one allow rule `Bash(<command>)` to `permissions.allow` in
   `.claude/settings.json` for each stack command: `test`, `test_quick`,
   `typecheck`, `lint`, and `verify`. Add a rule only for a command that
   exists. Use the exact command. If a command joins commands with `&&`,
   add one rule for each part. Remove the spaces at the start and end of
   each part. Do not make a rule for a part that is empty or has `*`. A
   rule with `*` lets Claude run other commands with no approval. Tell the
   user which parts got no rule.

For `container-ghcr`:

1. If fast tests is `No`: remove the `test-quick` hook from
   `.pre-commit-config.yaml`. Remove the `test_quick` key from
   `.claude/project.md`. Remove the `{{test_quick}}` row from the command
   table in `CLAUDE.md`.
2. Add one allow rule `Bash(<command>)` to `permissions.allow` in
   `.claude/settings.json` for each stack command: `test`, `test_quick`,
   and `lint`. Use the rule form of the `web-app` item 5. If a command
   joins commands with `&&`, add one rule for each part. Remove the spaces
   at the start and end of each part. Do not make a rule for a part that
   is empty or has `*`. Tell the user which parts got no rule.

For `ios-app`:

1. If Swift package is `No`: remove the `swift` entry from
   `.github/dependabot.yml`. Dependabot reports an error when it finds no
   `Package.resolved`. Keep the entry if the user did not say `No`.

## Step 9: Apply the setup answers

Collect the changes for these answers. Show each change. Ask for approval.
If the user approves, make the changes. If the user does not approve a
change, skip it and add it to the skipped list.

1. Private repo: add a `required_checks` line to the end of the list in
   `.claude/project.md`. Use the check names of the family:
   - `static-site-cloudflare` and `static-site-host`:
     `secrets-scan / trufflehog, semgrep-cloud-platform/scan, GitGuardian Security Checks, site / Build, site / Lint (Markdown)`
   - `web-app`: `secrets-scan / trufflehog, semgrep-cloud-platform/scan, GitGuardian Security Checks, App`
   - `container-ghcr`:
     `secrets-scan / trufflehog, semgrep-cloud-platform/scan, GitGuardian Security Checks, image / Lint (Dockerfile), image / Build, App`
   - `ios-app` and `other`:
     `secrets-scan / trufflehog, semgrep-cloud-platform/scan, GitGuardian Security Checks`

   The line has this form:

   ```markdown
   - required_checks: `secrets-scan / trufflehog, semgrep-cloud-platform/scan, GitGuardian Security Checks`
   ```

   Then run `flow-project-check`. If it fails, show the error and fix the
   line with the user.
2. Outside contributors: pin the devkit callers to the latest devkit
   release. Get the tag and its full commit SHA:

   ```sh
   gh release view -R unibrain1/devkit --json tagName --jq .tagName
   gh api repos/unibrain1/devkit/commits/<tag> --jq .sha
   ```

   If one of the two commands fails, show the output. Record the pin as
   failed. Go to item 3.

   Show the command `flow-template --pin <sha> <tag>`. After approval, run
   it. If it exits with a code that is not 0, show the output. Record the
   pin as failed. For exit 3, read the `Wrote:` list in stderr. Record
   those files as pinned. Exit 3 also means that temp files
   (`.flow-template.*`) can stay in the repo. Then stderr names them.
   Tell the user to remove them before Step 15.

   If it exits 0 and prints `Changed no file.`, show the output. Record
   the pin as failed. A new repo always has devkit callers, so a run that
   pins no file is an error.
3. Secrets or a database, and the family is not `web-app`: show the
   command `flow-template --env-hook`. It adds the `.env` block hook.
   `web-app` has the hook already. After approval, run it. If it exits
   with a code that is not 0, show the output. Record the hook as failed.
   For exit 3, tell the user to remove the temp files that stderr names
   before Step 15.

## Step 10: Install the packages

Do this step only for `static-site-cloudflare` and `static-site-host`.

1. Show the command `npm install`. Tell the user that it makes
   `package-lock.json`. The first commit must hold that file. Without it,
   `npm ci` in CI fails.
2. Ask for approval. If the user approves, run `npm install`. If not,
   skip this step and add it to the skipped list.
3. If `npm install` fails, show the output. Add it to the skipped list.

## Step 11: Check for placeholders

1. Run `flow-template --leftover`. It must exit 0.
2. If it exits 1, show each line. Fix each placeholder with the user. Show
   each fix as a diff and ask for approval. Run `flow-template --leftover`
   again.
3. If it exits 1 after the fixes, or exits 2, show the output. Stop.

## Step 12: Add the flow block and the labels

1. Run `flow-claude-block --status`. If it prints `current`, go to item 3.
2. Run `flow-claude-block --diff`. Show the diff. Ask for approval. If the
   user approves, run `flow-claude-block --apply`. If not, add the block
   to the skipped list.
3. Run `flow-labels --missing`.
   - Exit 0: no label is missing. Go to Step 13.
   - Exit 1: one or more labels are missing. Do item 4.
   - Exit 2, or any other exit code: show its stderr. Add the labels to
     the skipped list. Go to Step 13.
4. Show the missing labels as a table: name, color, description. Ask for
   approval. If the user approves, run `flow-labels --create`. If not, add
   the labels to the skipped list.
5. If `flow-labels --create` fails, show the output. Add the labels to the
   skipped list.

## Step 13: Install the enabled plugins

1. Run `flow-plugins --status`. Keep the `missing`, `stale`, and `unknown`
   lines. This step runs `flow-plugins --status` with no `--running`, so
   no `stale-running` line shows here.
   - Exit 0: no enabled plugin is missing or stale. Go to Step 14.
   - Exit 1: one or more `missing` or `stale` lines.
   - Exit 2, or any other exit code: show its stderr. Record the plugins
     as failed. Go to Step 14.
2. Read `${CLAUDE_PLUGIN_ROOT}/commands/setup.md`, "Step 7: Install or
   update the enabled plugins". Do its items 1 to 6. That step asks for
   approval before it runs a command. Item 6 runs `flow-plugins --status`
   again.
3. Do not do items 7 and 8 of that step. Item 7 compares
   `.claude/settings.json` with the file in `HEAD`, but the repo has no
   commit yet. The report gives `/reload-plugins` (item 8).
4. Do not tell the user to run `/reload-plugins` yet. The report tells
   the user.

## Step 14: Install the pre-commit hooks

1. Run `command -v pre-commit`. If it fails, add `pre-commit install` to
   the skipped list. Go to Step 15.
2. Show the command `pre-commit install`. Ask for approval.
3. If the user approves, run `pre-commit install`. If not, add it to the
   skipped list.
4. If `pre-commit install` fails, show the output. Add it to the skipped
   list.

## Step 15: Commit and push

1. Run `git status --short`. Show the full file list.
2. Do this item only if `.DS_Store` exists in the repo root and the family
   is not `ios-app`. Only the `ios-app` `.gitignore` ignores `.DS_Store`.
   Without this item, `git add -A` adds the file to the commit. Show the
   command `rm .DS_Store`. Ask for approval. If the user approves, run
   `rm .DS_Store`. If not, tell the user that the commit holds the file.
3. Show the commands:

   ```text
   git add -A
   git commit -m "chore: start from the <family> template"
   git push -u origin main
   ```

4. Ask for approval. If the user does not approve, tell the user to commit
   and push. Go to Step 16.
5. If the user approves, run the commands in this order. Run `git push`
   only if `git commit` succeeds:

   ```sh
   git add -A
   git commit -m "chore: start from the <family> template"
   git push -u origin main
   ```

6. If a pre-commit hook stops the commit, show the output. Fix the cause
   with the user. Do not skip the hook. Then run `git commit` again, then
   `git push`. If the user cannot fix the cause, record the result as
   "not committed". Go to Step 16.
7. If `git commit` fails for a cause that is not a pre-commit hook, show
   the output. Do not run `git push`. Record the result as "not
   committed". Go to Step 16.
8. If `git commit` succeeds and `git push` fails, show the push output.
   Record the result as "committed, not pushed". Go to Step 16.

## Step 16: Report

Print a short report:

- Family: the family name.
- GitHub repo: the name and the visibility.
- Files: the count of files in the first commit, or "not committed".
  Add the commit output if the commit failed. Add "committed, not pushed"
  with the push output if the push failed.
- Plugins: installed or updated (with the names), all current, failed, or
  skipped. List each `unknown` plugin.
- Labels: created (with the count), none missing, or skipped.
- Pin: pinned to `<tag>` (with the files), failed (with the output),
  skipped, or not asked. For a `--pin` exit 3, list the pinned files from
  its `Wrote:` lines.
- .env hook: added, in place already (`web-app`), failed (with the
  output), skipped, or not asked.
- Skipped steps: list each step that you skipped, with the reason:

  ```markdown
  Skipped steps:
  - <step>: <reason>
  ```

  Write "Skipped steps: none" when no step skipped.
- Manual steps. This command cannot do them:
  1. Add the repo in the Semgrep GitHub App and in the GitGuardian GitHub
     App.
  2. Install the Claude GitHub App on the repo.
  3. Add the `CLAUDE_CODE_OAUTH_TOKEN` repo secret.
  4. Public repo: turn on secret scanning and push protection. Add the
     check names of the family (Step 9, item 1) to branch protection on
     `main`.
  5. If the repo has the `.env` block hook, install `jq` on each machine
     that runs Claude Code. The hook needs `jq`. A `web-app` repo has the
     hook. Another family has it if `flow-template --env-hook` ran.
  6. The steps of the family below.

For `static-site-cloudflare`:

1. Make a Cloudflare Pages project. Connect it to the GitHub repo through
   the Git integration. Set the production branch to `main`.
2. Set the build command to `npm run build` and the output folder to
   `_site`.
3. If the site has Pages Functions, set `pages_functions: true` in
   `.github/workflows/ci.yml`.

For `static-site-host`:

1. Check that the host has Node, npm, and rsync.
2. Add a webhook in the GitHub repo. It calls the deploy script on the
   host for each push to `main`.
3. Check that the deploy script gets `main`, runs `npm run build`, and
   copies `_site/` to the web folder with rsync.
4. Install the PHP CLI on each machine that commits.
5. If the site has no `composer.json`, remove the `composer` entry from
   `.github/dependabot.yml`.

For `web-app`:

1. Add the setup steps of the stack to the `App` job in
   `.github/workflows/ci.yml`. Use the commented examples.
2. Add the stack folders to `.gitignore`.
3. Public repo: turn on CodeQL default setup.
4. Do the host steps. Cloudflare Pages: connect the Pages project to the
   repo, with `main` as the production branch. A2 Hosting: add the deploy
   remote. Check that its post-receive hook deploys the pushed commit.

For `container-ghcr`:

1. Add a Dockerfile at the root of the repo. Or set the `dockerfile` and
   `context` inputs in `.github/workflows/container-image.yml`.
2. Install Docker on each machine that commits. The `hadolint` hook needs
   it.
3. Add the setup steps of the stack to the `App` job in
   `.github/workflows/ci.yml`.
4. After the first push to `main`, open the GHCR package. Set its
   visibility, and link it to the repo.
5. Before the first release, set the pull tag on the host to `latest` or
   to a version tag.

For `ios-app`:

1. Install Xcode, then `brew install swiftlint pre-commit`, on each Mac
   that commits.
2. Open Xcode one time and accept the license.
3. Make the Xcode project in the repo.

Then give the next steps. Tell the user to type each command:

1. `/reload-plugins`. The plugins load after it.
2. `/flow:plan-milestone`.

`/flow:new-project` has no `model:` key, so it starts no command with the
Skill tool. See the `flow:workflow` skill, "Hand-offs between commands".
