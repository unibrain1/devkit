# devkit

Shared Claude Code workflow and CI for the unibrain1 projects.

This repo will hold:

- `plugins/flow/` — the `flow` Claude Code plugin: milestone and issue
  commands, generic agents, workflow scripts in `bin/`, and guard hooks.
- `.github/workflows/` — reusable CI workflows that project repos call.

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
[docs/project-md.md](docs/project-md.md).

## Tests

```sh
bash tests/run.sh
```

## Contributing

After the first commit, every change goes to `main` through a pull request.

## License

MIT. See [LICENSE](LICENSE). Third-party plugins in the marketplace keep
their own licenses. See [docs/sources.md](docs/sources.md).
