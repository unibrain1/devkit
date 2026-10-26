# devkit

Shared Claude Code workflow and CI for the unibrain1 projects.

This repo will hold:

- `plugins/flow/` — the `flow` Claude Code plugin: milestone and issue
  commands, generic agents, skills, and workflow scripts.
- `.github/workflows/` — reusable CI workflows that project repos call.

The design is in [docs/design.html](docs/design.html). The repo is in
rollout phase 1 (build). Do not use it in a project before tag `v0.1.0`.

## Contributing

After the first commit, every change goes to `main` through a pull request.
