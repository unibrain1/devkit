# Project facts for devkit commands

The flow commands read this file. Claude Code does not load it in a normal
session. Each fact is one line: a dash, the key, a colon, and the value in
backticks. The keys are in
<https://github.com/unibrain1/devkit/blob/main/docs/project-md.md>.

- test: `npm run build`
- lint: `npm run lint`
- plans: `docs/plans`
- deploy: `A push to main starts the host webhook. The host builds the site and copies it with rsync. See the Deployment section in CLAUDE.md.`
