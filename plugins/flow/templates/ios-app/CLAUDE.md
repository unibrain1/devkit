# CLAUDE.md — {{app_name}}

## Project Overview

{{app_description}}

The repo holds an Xcode project for an iOS app. The repo uses the devkit
`ios-app` template.

| Command | What it does |
| --- | --- |
| `{{test}}` | Runs all the tests in the iOS Simulator. The pre-push hook runs it before each push. |
| `swiftlint lint --strict` | Runs SwiftLint. The pre-commit hook runs it, with `--force-exclude`, on the staged Swift files at each commit. |

The repo has no macOS CI job for the app, so the tests run on the Mac
before each push. If the test command pipes the output to a formatter, for
example `xcbeautify`, start it with `set -o pipefail;`. Without it, failed
tests do not stop the push.

## Setup

Do these steps one time on each Mac:

1. Install Xcode from the App Store.
2. Open Xcode one time and accept the license. If `xcode-select -p` does
   not show `Xcode.app`, run
   `sudo xcode-select -s /Applications/Xcode.app`.
3. Install SwiftLint and pre-commit: `brew install swiftlint pre-commit`.

Then do this step one time in each clone:

1. Run `pre-commit install`. It installs the pre-commit hook and the
   pre-push hook.

## Deployment

The app reaches a device through an Xcode sideload. This template has no
TestFlight or App Store step.

1. Connect the iPhone to the Mac, or pair it over Wi-Fi in Xcode.
2. On the first install, turn on Developer Mode on the iPhone: Settings,
   Privacy & Security, Developer Mode. The iPhone restarts. If Settings
   shows no Developer Mode item, click Run in Xcode one time. Then the
   item shows.
3. In Xcode, open the project. Select the app target, then Signing &
   Capabilities. Set the Team to your Apple ID.
4. Select the iPhone as the run destination. Click Run.
5. On the first install, trust the developer on the iPhone: Settings,
   General, VPN & Device Management.

A free Apple ID gives a provisioning profile that expires after 7 days.
After that, the app does not open. Run it from Xcode again.

## Key Conventions

- Write plan files in `docs/plans/`. Git ignores that folder.
- Keep the Swift packages in the Xcode project. Commit `Package.resolved`:
  Dependabot reads it.
- Keep the SwiftLint settings in `.swiftlint.yml`.

## Never Do

- Do not commit a certificate or a provisioning profile.
- Do not commit `DerivedData/`, `build/`, or `xcuserdata/`.
- Do not push with `--no-verify`. The pre-push hook runs the tests.
- Do not push to `main` directly. Use a PR.

<!-- flow:begin rev 1 -->
## Developer workflow (flow)

Branches: `main` ← `milestone/vX.Y.Z` ← `issue/NNN-slug`. One PR for each
issue, to the milestone branch. A hotfix branches from `main` (the
`flow:hotfix` skill).

```text
/flow:plan-milestone → /flow:start-milestone
  per issue: /flow:start-issue → /flow:execute-plan → /commit → /flow:review-pr
             → /flow:commit-push-pr → /flow:address-pr-comments → /flow:finish-issue
/flow:finish-milestone → /flow:review-milestone → /flow:release-milestone
```

Hand-offs: start the next command through the Skill tool only when both
commands declare the same `model:`. Otherwise, tell the user to type it.
At an issue or milestone boundary, recommend `/clear` first.

Project facts for these commands are in `.claude/project.md`. The full
method is in the `flow:workflow` skill.
<!-- flow:end -->
