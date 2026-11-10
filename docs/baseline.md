# Every-repo baseline

The baseline is a set of files that every repo gets, for any stack. It
holds the checks that do not depend on the language or the framework. The
files are in `plugins/flow/templates/baseline/`. A path in that folder is
the path in the target repo.

Each family template copies the baseline files. `/flow:setup` adds the
missing files to a repo that has no family template. Stack checks stay in the family template or in the
project.

## Files

| File | What it does |
| --- | --- |
| `.pre-commit-config.yaml` | The pre-commit framework hooks. File checks from `pre-commit/pre-commit-hooks`: trailing-whitespace, end-of-file-fixer, check-yaml, check-json, check-merge-conflict, check-added-large-files. markdownlint from `DavidAnson/markdownlint-cli2`. gitleaks from `gitleaks/gitleaks`, on the staged files. Each hook pins a release tag in `rev:`. A commented `test_quick` block. |
| `.github/workflows/claude-code-review.yml` | The caller of `claude-review.yml`, with its `permissions:` block. |
| `.github/workflows/claude.yml` | The caller of `claude.yml`, with its `permissions:` block. |
| `.github/workflows/secrets-scan.yml` | The caller of `secrets-scan.yml`. The job ID is `secrets-scan`, so the check name is `secrets-scan / trufflehog`. |
| `.github/dependabot.yml` | Dependabot for the `github-actions` ecosystem, weekly, with the commit prefix `chore(deps):`. It ignores `unibrain1/devkit`, because the devkit pin moves only by hand. |

The three callers are the examples in [ci-workflows.md](ci-workflows.md).
They use `@main`. A repo with outside contributors changes them to a tag.
See the [devkit pin rule](ci-workflows.md#devkit-pin-rule).

The hook revs stay pinned until a person changes them. No tool updates
them.

## Turn on the hooks

The pre-commit framework does not run until each clone installs it. After
the files are in the repo, run this in each clone:

```sh
pre-commit install
```

## The `test_quick` slot

`.pre-commit-config.yaml` has a commented `repo: local` block for the
project's fast tests. The block is off. To turn it on, a family template
or the user removes the first `#` mark from each line from
`- repo: local` to the `stages` line. Then they replace the `entry:`
placeholder with the command in the `test_quick` key of
`.claude/project.md`.

If `test_quick` takes more than about 20 seconds, the repo moves it to
pre-push. Remove the second `#` mark from the `stages: [pre-push]` line
too. Then run `pre-commit install --hook-type pre-push`. A slow hook on
each commit makes people skip the hooks.

## Secret scans

Every repo runs `secrets-scan.yml`. trufflehog keeps its default
`--only-verified`, so it reports only a secret that it can verify. The
caller sets no `extra_args`.

A public repo also turns on secret scanning and push protection in its
settings. GitHub gives both at no cost to a public repo. In a public repo,
trufflehog and push protection both run.

## Needed checks

These checks must pass before a merge:

- `secrets-scan / trufflehog`
- `semgrep-cloud-platform/scan`

The project adds its own stack checks to the list.

## Merge gate rule

The merge gate makes a merge stop when a needed check did not pass:

- **Private repo:** list the needed checks in the `required_checks` key of
  `.claude/project.md`. See [project-md.md](project-md.md). Branch
  protection is not available for a private repo on GitHub Free, so
  `finish-issue` and `release-milestone` do the check.
- **Public repo:** use branch protection on `main`, with the needed
  checks as required status checks.

Write each name as `gh pr checks --json name` prints it.

## GitHub Apps

Each repo needs these GitHub Apps:

- **Semgrep.** It runs the `semgrep-cloud-platform/scan` check.
- **GitGuardian.** It scans each push and each PR for secrets.

An app does not add a new repo automatically. Jim adds each repo in each
app, in the app's settings.

The Claude callers also need these items:

- **The Claude GitHub App.** Install it on the repo.
- **The `CLAUDE_CODE_OAUTH_TOKEN` repo secret.** The callers need it. See
  [ci-workflows.md](ci-workflows.md).

Claude does not review the PR that adds `claude-code-review.yml`, because
the caller is not on `main` yet. See the
[main-match rule](design.html#main-match).

## Add the baseline to a repo

`/flow:setup` adds the missing baseline files:

1. It runs `flow-baseline --status`. The script prints one line for each
   baseline file: `missing <path>`, `same <path>`, or `different <path>`.
2. It shows the missing files and asks for approval.
3. After approval, it runs `flow-baseline --apply <path>...` to copy them.

`/flow:setup` adds only missing files. A different file is reported, never
changed. Compare it with the template and merge by hand if you want the
change.

After the files are in the repo, do the manual steps:

1. Run `pre-commit install` in each clone.
2. Ask Jim to add the repo in the Semgrep and GitGuardian apps.
3. Install the Claude GitHub App on the repo. Add the
   `CLAUDE_CODE_OAUTH_TOKEN` repo secret.
4. In a public repo, turn on secret scanning and push protection. Set the
   needed checks in branch protection.
5. In a private repo, set the `required_checks` key in
   `.claude/project.md`.
