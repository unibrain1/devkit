# Repo families

A repo family is a set of repos with the same stack. All repos in one
family get the same files from one family template. The templates are in
`plugins/flow/templates/<family>/`. A path in that folder is the path in
the target repo.

## Layering rule

A target repo gets its files in two layers:

1. The baseline files. See [baseline.md](baseline.md).
2. The family files.

A family file at a baseline path replaces the baseline file. The family
file holds the full baseline content with no change, then the family
additions. A test checks that each baseline entry and each baseline line
is in the family file. A family
folder holds no other copy of a baseline file.

Only these overrides are allowed:

| Family | Override | Addition |
| --- | --- | --- |
| `static-site-cloudflare` | `.github/dependabot.yml` | The `npm` entry. |
| `static-site-host` | `.github/dependabot.yml` | The `npm` entry and the `composer` entry. |
| `static-site-host` | `.pre-commit-config.yaml` | A `repo: local` hook that runs `npm run lint`. |
| `web-app` | `.pre-commit-config.yaml` | A `repo: local` block with the `typecheck` and `test-quick` hooks. |
| `container-ghcr` | `.github/dependabot.yml` | The `docker` entry and the stack entry (`"{{stack_ecosystem}}"`). |
| `container-ghcr` | `.pre-commit-config.yaml` | A `repo: local` block with the `hadolint` and `test-quick` hooks. |

## Family A: static sites

Family A is the Node static sites that Eleventy builds. Eleventy reads
`src/` and writes `_site/`. CI calls the reusable `node-site.yml`. See
[ci-workflows.md](ci-workflows.md#node-siteyml). CI builds and lints. It
does not deploy.

Family A has two templates. Each template has its own deploy path.

### `static-site-cloudflare`

Cloudflare Pages deploys `main` through its Git integration.

| File | What it holds |
| --- | --- |
| `.github/workflows/ci.yml` | The `node-site.yml@main` caller, with no `with:`. A comment shows `pages_functions: true` for a site with Pages Functions. |
| `.github/dependabot.yml` | Override. The baseline `github-actions` entry, then a weekly `npm` entry. |
| `.claude/project.md` | `test`, `lint`, `plans`, and `deploy`. |
| `.claude/settings.json` | `templates/settings.json`, plus allow `npm run build` and `npm run lint`, and deny `Read` and `Edit` in `node_modules/` and `_site/`. |
| `.claude/rules/site-review.md` | A stub with the sections Site and build, Pages Functions (optional), and Docs. |
| `CLAUDE.md` | A skeleton: Project Overview, Deployment, Key Conventions, Never Do, and the flow block. |
| `package.json` | The scripts `build`, `serve`, `clean`, and `lint` (`markdownlint-cli2`). The devDependencies `@11ty/eleventy` and `markdownlint-cli2`. |
| `eleventy.config.js` | Input `src`, output `_site`. |
| `.markdownlint-cli2.jsonc` | The markdownlint settings. It ignores `node_modules/` and `_site/`. |
| `.nvmrc` | Node `24`. |
| `.gitignore` | `node_modules/`, `_site/`, `.env`, `.env.*` (but not `.env.example`), `.dev.vars`, and `docs/plans/`. |

### `static-site-host`

A push to `main` starts a webhook on the host. The host builds the site
and copies `_site/` to the web folder with rsync. The site can have PHP
pages.

| File | What it holds |
| --- | --- |
| `.github/workflows/ci.yml` | The `node-site.yml@main` caller, with `lint_script: lint`. |
| `.github/dependabot.yml` | Override. The baseline `github-actions` entry, then a weekly `npm` entry and a weekly `composer` entry. The `composer` entry uses `directory: /`. If `composer.json` is in a subfolder, change the directory. |
| `.pre-commit-config.yaml` | Override. The baseline hooks, then a `repo: local` hook. The hook runs `npm run lint` when a CSS or PHP file changes. |
| `.claude/project.md` | `test`, `lint`, `plans`, and `deploy`. |
| `.claude/settings.json` | The same as in `static-site-cloudflare`. |
| `.claude/rules/site-review.md` | A stub with the sections Site and build, PHP, and Docs. |
| `CLAUDE.md` | A skeleton: Project Overview, Deployment, Key Conventions, Never Do, and the flow block. |
| `package.json` | The `static-site-cloudflare` scripts, plus `lint:md`, `lint:css` (stylelint), and `lint:php` (`php -l`). Here `lint` runs the three. The devDependencies also have `stylelint` and `stylelint-config-standard`. |
| `eleventy.config.js` | Input `src`, output `_site`. |
| `.markdownlint-cli2.jsonc` | The markdownlint settings. It ignores `node_modules/` and `_site/`. |
| `.stylelintrc.json` | Extends `stylelint-config-standard`. It ignores `_site/` and `vendor/`. |
| `.nvmrc` | Node `24`. |
| `.gitignore` | `node_modules/`, `_site/`, `.env`, `.env.*` (but not `.env.example`), `.dev.vars`, and `docs/plans/`. |

`lint:php` runs `php -l` on each PHP file outside `node_modules/`,
`vendor/`, and `_site/`. It needs no PHP framework. If the repo has no
PHP file, it passes. It runs `php -l` one time for each file, because
PHP before 8.3 checks only the first file of a list. If one file fails,
the script fails. In CI, `php -l`
uses the PHP on the `ubuntu-24.04` runner image. The workflow does not
install PHP.

## Family W: web apps

Family W is the web apps with a database and a version, for example a
TypeScript app on Cloudflare Pages and Supabase, or a PHP and MySQL app on
A2 Hosting. The stacks differ, so the `web-app` template holds no stack
file. Each stack command is a placeholder. `/flow:new-project` (#117)
fills it from the setup answers.

### `web-app`

| File | What it holds |
| --- | --- |
| `.github/workflows/ci.yml` | The `App` job. It runs on each PR and on each push to `main` and `milestone/**`. It checks out the repo, then runs `{{lint}}` and `{{test}}`. Commented examples show the Node and the PHP setup steps, with pinned SHAs. |
| `.pre-commit-config.yaml` | Override. The baseline hooks, then a `repo: local` block. The `typecheck` hook runs `{{typecheck}}` and the `test-quick` hook runs `{{test_quick}}`, at each commit. Each hook runs its command through `bash -c`, because pre-commit runs `entry` with no shell. |
| `.claude/project.md` | `test`, `test_quick`, `lint` (`{{typecheck}} && {{lint}}`), `verify`, `plans`, `deploy`, `milestone_setup`, and `release_checks`. |
| `.claude/settings.json` | `templates/settings.json`, plus the PreToolUse hook on `Read\|Edit\|MultiEdit\|Write\|NotebookEdit\|Grep` that runs `"$CLAUDE_PROJECT_DIR"/.claude/hooks/block-env.sh`. |
| `.claude/hooks/block-env.sh` | The `.env` block hook. See [The `.env` block hook](#the-env-block-hook). |
| `.claude/rules/app-review.md` | A stub with the sections App and tests, Database, Secrets, and Docs. |
| `CLAUDE.md` | A skeleton: Project Overview, Deployment (`{{deployment}}`), Versioning, Key Conventions, Never Do, and the flow block. |
| `.gitignore` | `.env`, `.env.*` (but not `.env.example` and `.env.sample`), `.dev.vars`, `.dev.vars.*` (but not `.dev.vars.example`), and `docs/plans/`. |

The type check runs at each commit (the `typecheck` hook) and in the
`lint` key. The `{{lint}}` value is the lint command only, because the
`lint` key adds the type check. CI has no type check step: for a stack
with a type check, `/flow:new-project` writes the type check command,
then `&&`, then the lint command, in the `{{lint}}` step of `ci.yml`.

### Host

The host is a setup answer. The text for the Deployment section of
`CLAUDE.md` is in `plugins/flow/templates/web-app-hosts/`. That folder is
not copied to the repo. `/flow:new-project` must put the file of the
chosen host in place of `{{deployment}}`.

| Host | File | Deploy |
| --- | --- | --- |
| Cloudflare Pages | `cloudflare-pages.md` | Cloudflare Pages deploys `main` through its Git integration. |
| A2 Hosting | `a2-tag.md` | Two pushes to the deploy remote on the host: the release tag, then the tagged commit to `main`. |

### Devkit pin

The devkit pin is a setup answer. Each devkit caller in the baseline uses
`@main`. The `web-app` template adds no devkit caller. For a repo with
outside contributors, replace
`@main` on each `uses: unibrain1/devkit/` line with the full commit SHA of a
release tag and the tag in a comment:

```yaml
uses: unibrain1/devkit/.github/workflows/claude-review.yml@<full SHA> # vX.Y.Z
```

See the [devkit pin rule](ci-workflows.md#devkit-pin-rule).

### Version

The milestone branch `milestone/vX.Y.Z` names the version. The
`milestone_setup` key writes it into the app, and the `release_checks` key
stops a release when the two do not agree. `/flow:new-project` must put
the commands of one form in place of `{{milestone_setup}}` and
`{{release_checks}}`:

<!-- version-forms: tests/templates/test-family-w.sh runs these commands -->

| Form | `milestone_setup` | `release_checks` |
| --- | --- | --- |
| npm | `npm version "$(git branch --show-current \| sed 's#^milestone/v##')" --no-git-tag-version --allow-same-version` | `test "milestone/v$(jq -r .version package.json)" = "$(git branch --show-current)" \|\| { echo "package.json version does not match the milestone branch" >&2; exit 1; }` |
| VERSION file | `git branch --show-current \| sed 's#^milestone/v##' > VERSION` | `test "milestone/v$(cat VERSION)" = "$(git branch --show-current)" \|\| { echo "VERSION does not match the milestone branch" >&2; exit 1; }` |

Use the npm form when `package.json` holds the app version. Use the
VERSION form for another stack. The repo then tracks the `VERSION` file.

### The `.env` block hook

A web app keeps its database and API credentials in `.env` files.
Wrangler (Cloudflare) keeps local secrets in `.dev.vars`. The hook runs
before each Read, Edit, MultiEdit, Write, NotebookEdit, and Grep call. It
blocks a file named `.env`, `.env.<name>`, `.dev.vars`, or
`.dev.vars.<name>`, in any folder and in any letter case. A
case-insensitive file system, such as the macOS default, opens `.env` for
`.ENV`. The hook allows a name that ends in
`.example` or `.sample`.

The hook does not stop these:

- A Bash command, such as `cat .env`.
- A Grep with no `path`, or with a folder `path`. It can find lines in an
  `.env` file in that folder.
- A symlink to an `.env` file.

The hook blocks the call when it cannot do its check:

- `jq` is not installed.
- The hook input is empty or is not JSON.
- The hook file cannot run. The settings command adds
  `|| { echo "BLOCK: ..." >&2; exit 2; }`, because Claude Code blocks a
  call only on exit 2.

The settings run the hook through `$CLAUDE_PROJECT_DIR`, so the hook also
runs when the session works in a subfolder. Each Family W repo has a
database, so the hook is always on.

Each repo gets its own copy of the hook. A later fix to the hook in devkit
does not reach a repo that has a copy: change each copy by hand.

## Family B: container images

Family B is the repos that build a container image and push it to the
GitHub Container Registry (GHCR). A host pulls the image and runs it. The
stacks differ, so the `container-ghcr` template holds no stack file and
no Dockerfile. Each stack command is a placeholder. `/flow:new-project`
(#117) fills it from the setup answers.

CI calls the reusable `container-image.yml`. See
[ci-workflows.md](ci-workflows.md#container-imageyml). It lints the
Dockerfile with hadolint and builds the image. A PR only builds the image.
A push to `main` pushes the tags `edge` and `sha-<7 hex>`. A tag `vX.Y.Z`
pushes `X.Y.Z`, `X.Y`, and `latest`. The host pulls `latest` or a version
tag, never `edge`, a `sha-` tag, or `main`.

### `container-ghcr`

| File | What it holds |
| --- | --- |
| `.github/workflows/container-image.yml` | The `container-image.yml@main` caller. It runs on each PR, on each push to `main`, and on each `v[0-9]+.[0-9]+.[0-9]+` tag. All tag runs share one concurrency group. The job `image` has `contents: read` and `packages: write`. The job ID `image` gives the check names `image / Lint (Dockerfile)` and `image / Build`. A comment shows the `with:` inputs. |
| `.github/workflows/ci.yml` | The `App` job, as in `web-app`. It runs on each PR and on each push to `main` and `milestone/**`. It runs `{{lint}}` and `{{test}}`. Commented examples show the Node and the PHP setup steps, with pinned SHAs. |
| `.github/dependabot.yml` | Override. The baseline `github-actions` entry, then a weekly `docker` entry and a weekly stack entry. Both use `directory: /`. If the Dockerfile is in a subfolder, change the `docker` directory. |
| `.pre-commit-config.yaml` | Override. The baseline hooks, then a `repo: local` block. The `hadolint` hook runs the image `ghcr.io/hadolint/hadolint` at a pinned tag and digest. The `test-quick` hook runs `{{test_quick}}` through `bash -c` at each commit. |
| `.claude/project.md` | `test`, `test_quick`, `lint`, `plans`, and `deploy`. |
| `.claude/settings.json` | The same as `templates/settings.json`. |
| `.claude/rules/image-review.md` | A stub with the sections Image and Dockerfile, App and tests, Secrets, and Docs. |
| `CLAUDE.md` | A skeleton: Project Overview, Deployment (the image tags), Key Conventions, Never Do, and the flow block. |
| `.gitignore` | `.env`, `.env.*` (but not `.env.example`), and `docs/plans/`. |
| `.dockerignore` | `.git`, `.github`, `.claude`, `docs/plans/`, and `.env` and `.env.*` in each folder. The image does not need `.env.example`, so no rule keeps it. |

The `hadolint` hook runs hadolint in a Docker container at each commit.
Each machine that commits needs Docker. The upstream `hadolint-docker`
hook names the image with no tag, so its `rev` does not pin the image.
Thus the template uses a local hook with the tag and the digest in
`entry`. Dependabot does not update the entry. Change it by hand. CI does
not need the hook: the `image / Lint (Dockerfile)` job lints the
Dockerfile.

A hotfix also gets a patch tag, for example `v1.2.4`. The tag moves
`latest` to the fix, so the host gets it.

## Placeholders

A template file can hold a placeholder in the form `{{key}}`. Markdown and
JSON files can hold placeholders. In `web-app` and `container-ghcr`, a
YAML file can also hold a placeholder, but only as a full quoted value,
for example `run: "{{lint}}"` or the list item `- "{{typecheck}}"`. The
file then still parses. Family A YAML and JS files hold none. These are
the only placeholders:

| Placeholder | Value | Files |
| --- | --- | --- |
| `{{site_name}}` | The site name, for people to read. | Family A `CLAUDE.md` |
| `{{site_description}}` | One sentence about the site. | Family A `CLAUDE.md` |
| `{{package_name}}` | The npm package name: lowercase, with no spaces. | Family A `package.json` |
| `{{app_name}}` | The app name, for people to read. | `web-app` and `container-ghcr` `CLAUDE.md` |
| `{{app_description}}` | One sentence about the app. | `web-app` and `container-ghcr` `CLAUDE.md` |
| `{{deployment}}` | The text of one host file in `web-app-hosts/`. | `web-app` `CLAUDE.md` |
| `{{test}}` | The command that runs all the tests. | `web-app` and `container-ghcr` `project.md`, `ci.yml`, `CLAUDE.md` |
| `{{test_quick}}` | The command that runs the fast tests. | `web-app` and `container-ghcr` `project.md`, `.pre-commit-config.yaml`, `CLAUDE.md` |
| `{{typecheck}}` | The type check command. | `web-app` `project.md`, `.pre-commit-config.yaml`, `CLAUDE.md` |
| `{{lint}}` | The lint command, with no type check. In `ci.yml`, see [`web-app`](#web-app). | `web-app` and `container-ghcr` `project.md`, `ci.yml`, `CLAUDE.md` |
| `{{verify}}` | The full check before a release. | `web-app` `project.md`, `CLAUDE.md` |
| `{{milestone_setup}}` | The `milestone_setup` command of one version form. | `web-app` `project.md` |
| `{{release_checks}}` | The `release_checks` command of one version form. | `web-app` `project.md` |
| `{{stack_ecosystem}}` | The Dependabot ecosystem of the stack, for example `npm`, `pip`, or `gomod`. | `container-ghcr` `.github/dependabot.yml` |

## What `/flow:new-project` must do

`/flow:new-project` (#117) makes a repo from a family template. For a
Family A template, after it copies the files and replaces the
placeholders, it must run `npm install`.
`npm install` makes `package-lock.json`. Commit that file. Without it,
`npm ci` in CI fails. The templates hold no lock file, because the
package versions change.

For `web-app`, `/flow:new-project` must also do these steps:

1. Ask the stack commands and fill each command placeholder. For a stack
   with a type check, fill the `{{lint}}` step of `ci.yml` with the type
   check command, then `&&`, then the lint command.
2. In a YAML file, write each command as a valid double-quoted value:
   put `\` before each `"` and `\`. Refuse a command that holds `${{`. A
   GitHub expression in a `run:` value can inject code.
3. If the stack has no type check, remove the `typecheck` hook from
   `.pre-commit-config.yaml` and the `{{typecheck}} &&` prefix from the
   `lint` key. Remove the `{{typecheck}}` row from the command table in
   `CLAUDE.md`.
4. Put the chosen host file in place of `{{deployment}}`.
5. Put one version form in place of `{{milestone_setup}}` and
   `{{release_checks}}`.
6. Add the Dependabot entry of the stack (`npm` or `composer`) to
   `.github/dependabot.yml`.
7. Add an allow rule to `.claude/settings.json` for each stack command,
   as Family A allows `npm run build` and `npm run lint`.
8. For a repo with outside contributors, change the devkit pin (see
   [Devkit pin](#devkit-pin)).
9. Check that no placeholder from the [Placeholders](#placeholders) table
   is left in the repo. A GitHub expression, `${{ ... }}`, is not a
   placeholder: keep it.

For `container-ghcr`, `/flow:new-project` must do these steps:

1. Ask the stack commands and the Dependabot ecosystem of the stack. Fill
   each placeholder.
2. In a YAML file, write each value as a valid double-quoted value: put
   `\` before each `"` and `\`. Refuse a value that holds `${{`. A
   GitHub expression in a `run:` value can inject code.
3. If the stack has no fast tests, remove the `test-quick` hook from
   `.pre-commit-config.yaml`, the `test_quick` key from
   `.claude/project.md`, and the `{{test_quick}}` row from the command
   table in `CLAUDE.md`.
4. For a repo with outside contributors, change the devkit pin (see
   [Devkit pin](#devkit-pin)). In `container-ghcr`, the
   `container-image.yml` caller is also a devkit caller.
5. Check that no placeholder from the [Placeholders](#placeholders) table
   is left in the repo. A GitHub expression, `${{ ... }}`, is not a
   placeholder: keep it.

## Manual steps

After the files are in the repo, do the manual steps in
[baseline.md](baseline.md#add-the-baseline-to-a-repo). Then do the steps
for the template.

For `static-site-cloudflare`:

1. Make a Cloudflare Pages project for the repo.
2. Connect the project to the GitHub repo through the Git integration.
   Set the production branch to `main`.
3. Set the build command to `npm run build` and the output folder to
   `_site`.
4. If the site has Pages Functions, set `pages_functions: true` in
   `.github/workflows/ci.yml`.

For `static-site-host`:

1. Check that the host has Node, npm, and rsync.
2. Add a webhook in the GitHub repo that calls the deploy script on the
   host for each push to `main`.
3. Check that the deploy script gets `main`, builds the site with
   `npm run build`, and copies `_site/` to the web folder with rsync.
4. Install the PHP CLI on each machine that commits, and run
   `npm install` one time in each clone. The pre-commit hook runs
   `npm run lint`, and `lint:php` needs `php`.
5. If the site has no `composer.json`, remove the `composer` entry from
   `.github/dependabot.yml`. Dependabot reports an error for an entry
   with no manifest.

For both templates:

1. In a public repo, add the CI checks to branch protection on `main`, for
   example `site / Build` and `site / Lint (Markdown)`.
2. In a private repo, add the CI checks to the `required_checks` key in
   `.claude/project.md`. See [project-md.md](project-md.md).

For `web-app`:

1. Add the setup steps of the stack to the `App` job in
   `.github/workflows/ci.yml`. Use the commented examples.
2. Add the stack folders (for example `node_modules/` or `vendor/`) to
   `.gitignore`.
3. Install `jq` on each machine that runs Claude Code. The `.env` block
   hook needs it.
4. In a public repo, turn on CodeQL default setup (Settings, then Code
   security). It runs next to the Semgrep app. Add the `App` check to
   branch protection on `main`.
5. In a private repo, add `App` to the `required_checks` key in
   `.claude/project.md`.
6. Do the host steps. For Cloudflare Pages, connect the Pages project to
   the repo, with `main` as the production branch. For A2 Hosting, add
   the deploy remote and check that its post-receive hook deploys the
   pushed commit.

For `container-ghcr`:

1. Add a Dockerfile at the root of the repo. Or set the `dockerfile` and
   `context` inputs in `.github/workflows/container-image.yml`, and
   change the `docker` directory in `.github/dependabot.yml`.
2. Install Docker on each machine that commits. The `hadolint` hook
   needs Docker at each commit. Then run `pre-commit install` in each
   clone.
3. Add the setup steps of the stack to the `App` job in
   `.github/workflows/ci.yml`. Use the commented examples.
4. After the first push to `main`, open the GHCR package of the image. Set
   the package visibility, and link the package to the repo.
5. Before the first release, change the pull tag on the host to `latest`
   or to a version tag. See
   [ci-workflows.md](ci-workflows.md#host-pull-tag).
6. In a public repo, add the checks `image / Lint (Dockerfile)`,
   `image / Build`, and `App` to branch protection on `main`.
7. In a private repo, add the same checks to the `required_checks` key in
   `.claude/project.md`.
