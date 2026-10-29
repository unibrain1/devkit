# Project facts for devkit commands

- test: `bash tests/run.sh`
- lint: `npx --no-install markdownlint-cli2 && yamllint --strict . && actionlint && shellcheck plugins/flow/bin/flow-* plugins/flow/bin/lib/*.sh plugins/flow/hooks/*.sh tests/*.sh tests/*/*.sh .github/scripts/*.sh`
- plans: `docs/plans`
- private_paths: `docs/plans`
