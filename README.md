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

After `v0.1.0`, add the marketplace and turn on the plugins:

```text
/plugin marketplace add unibrain1/devkit
/plugin install flow@devkit
/plugin install asd-ste100@devkit
```

Each repo also needs a `.claude/project.md`. See
[docs/project-md.md](docs/project-md.md). Copy
[templates/settings.json](templates/settings.json) to `.claude/settings.json`
one time. See [docs/settings-template.md](docs/settings-template.md).

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
