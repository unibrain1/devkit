# App review rules

Reviewers and agents read these rules when they check a change to this
app. Add the rules of this app to each section.

## App and tests

- The `lint` and `test` commands in `.claude/project.md` must pass.
- A change to app behavior has a test that fails without the change.

## Database

- Each schema change is a migration file in the repo. Do not change the
  production schema by hand.
- Use parameterized queries. Do not build SQL from user input.

## Secrets

- Read each secret from the environment. Do not write a secret in the
  code.
- Do not read or change an `.env` or `.dev.vars` file. The `.claude/hooks/block-env.sh`
  hook blocks it.

## Docs

- When a change alters the build, the deploy, or the version, update
  CLAUDE.md in the same change.
