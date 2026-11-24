# Image review rules

Reviewers and agents read these rules when they check a change to this
repo. Add the rules of this repo to each section.

## Image and Dockerfile

- hadolint must pass on each Dockerfile.
- Pin each base image to a version tag, not `latest`.
- Do not copy a secret into the image. Do not pass a secret as a build
  argument.
- Keep `.dockerignore` up to date, so that the build context holds no
  secret and no local file.

## App and tests

- The `lint` and `test` commands in `.claude/project.md` must pass.
- A change to app behavior has a test that fails without the change.

## Secrets

- Read each secret from the environment at run time. Do not write a
  secret in the code or in the image.
- Do not read, change, or commit an `.env` file.

## Docs

- When a change alters the build, the image tags, or the deploy, update
  CLAUDE.md in the same change.
