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

## Placeholders

A template file can hold a placeholder in the form `{{key}}`. Only
Markdown and JSON files hold placeholders. YAML and JS files hold none, so
each one parses and lints with no change. These are the only placeholders:

| Placeholder | Value | Files |
| --- | --- | --- |
| `{{site_name}}` | The site name, for people to read. | `CLAUDE.md` |
| `{{site_description}}` | One sentence about the site. | `CLAUDE.md` |
| `{{package_name}}` | The npm package name: lowercase, with no spaces. | `package.json` |

## What `/flow:new-project` must do

`/flow:new-project` (#117) makes a repo from a family template. After it
copies the files and replaces the placeholders, it must run `npm install`.
`npm install` makes `package-lock.json`. Commit that file. Without it,
`npm ci` in CI fails. The templates hold no lock file, because the
package versions change.

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
