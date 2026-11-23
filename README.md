# devkit

Shared Claude Code workflow and CI for the unibrain1 projects.

This repo will hold:

- `plugins/flow/` — the `flow` Claude Code plugin: milestone and issue
  commands, generic agents, workflow scripts in `bin/`, and guard hooks.
- `.github/workflows/` — reusable CI workflows that project repos call. See
  [docs/ci-workflows.md](docs/ci-workflows.md).
- `plugins/brain/skills/` — skills for the Claude desktop and phone apps.
  They are not a Claude Code plugin yet. Upload each one as a zip at
  claude.ai → Settings → Customize → Skills.

## Brain skill zips

Each push to `main` that changes `plugins/brain/skills/` runs
`release-skills.yml`. It replaces the release `skills-latest` with one zip
for each skill. Get the zips:

```sh
gh release download skills-latest -R unibrain1/devkit -p '*.zip' --clobber
```

To build them locally, run `.github/scripts/package-skills.sh`. It writes
`dist/<skill>.zip`, and git ignores `dist/`. The script first checks the
claude.ai upload rules, for example no `<` or `>` in the description.

The design is in [docs/design.html](docs/design.html). The repo is in
rollout phase 1 (build). Do not use it in a project before tag `v0.1.0`.

## Install

Do not run `/plugin marketplace add unibrain1/devkit`. It writes a
`devkit` entry with no `ref` in `~/.claude/settings.json`, and then
`/plugin` fails in each project that sets a `ref`.

For an existing repo:

1. Copy [templates/settings.json](templates/settings.json) to
   `.claude/settings.json`. It holds the `devkit` marketplace entry and
   `enabledPlugins`. See [docs/settings-template.md](docs/settings-template.md).
2. Start one Claude Code session in the repo and trust the project.
3. Run `/flow:setup`. It creates `.claude/project.md` (see
   [docs/project-md.md](docs/project-md.md)) and, after your approval,
   installs the enabled plugins at project scope.
4. Run `/reload-plugins`.

For a new repo, run `/flow:new-project`. It makes the repo from a family
template. See [docs/families.md](docs/families.md). The empty folder has
no `.claude/settings.json`, so start the session with the marketplace copy
of `flow`:

```sh
claude --plugin-dir ~/.claude/plugins/marketplaces/devkit/plugins/flow
```

Install at project scope. A user-scope install loads `flow` in every repo
(design section 5).

## Work on devkit with flow

devkit does not install `flow` from the marketplace. Start each devkit
session with the working copy:

```sh
claude --plugin-dir plugins/flow
```

Then the session runs the flow code on your branch. The one `devkit`
marketplace entry on the machine keeps the ref that other projects set.
A `.claude/settings.json` with `ref: main` in devkit would move that
entry for all projects.

The facts for the flow commands are in
[.claude/project.md](.claude/project.md).

## Tests and lint

```sh
bash tests/run.sh
```

CI (`.github/workflows/self-test.yml`) also runs shellcheck, actionlint,
yamllint, markdownlint, a JSON check, a check that each action is pinned to
a full commit SHA, and `claude plugin validate`. Branch protection on `main`
requires the jobs `lint` and `test`.

## Contributing

After the first commit, every change goes to `main` through a pull request.

## License

MIT. See [LICENSE](LICENSE). Third-party plugins in the marketplace keep
their own licenses. See [docs/sources.md](docs/sources.md).
