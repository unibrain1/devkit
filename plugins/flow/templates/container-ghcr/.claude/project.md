# Project facts for devkit commands

The flow commands read this file. Claude Code does not load it in a normal
session. Each fact is one line: a dash, the key, a colon, and the value in
backticks. The keys are in
<https://github.com/unibrain1/devkit/blob/main/docs/project-md.md>.

- test: `{{test}}`
- test_quick: `{{test_quick}}`
- lint: `{{lint}}`
- plans: `docs/plans`
- release_notes: `docs/releases/{version}.md`
- deploy: `See the Deployment section in CLAUDE.md.`
