# Project facts for devkit commands

The flow commands read this file. Claude Code does not load it in a normal
session. Each fact is one line: `- key: ` followed by the value in backticks.
The keys are in https://github.com/unibrain1/devkit/blob/main/docs/project-md.md

- test: `{{test}}`
- lint: `{{lint}}`
