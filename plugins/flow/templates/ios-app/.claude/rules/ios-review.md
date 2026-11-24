# iOS review rules

Reviewers and agents read these rules when they check a change to this
app. Add the rules of this app to each section.

## App and tests

- The `test` command in `.claude/project.md` must pass.
- A change to app behavior has a test that fails without the change.
- Do not edit or commit a file in `DerivedData/`, `build/`, or `.build/`.
  Xcode and SwiftPM make them.

## SwiftLint

- `swiftlint lint --strict` must pass.
- Do not turn off a SwiftLint rule in a source file without a comment that
  gives the reason.

## Signing and secrets

- Do not commit a signing file: a certificate (`.cer`, `.p12`) or a
  provisioning profile (`.mobileprovision`, `.provisionprofile`).
- Do not write an API key or a password in the code.
- Do not read, change, or commit an `.env` file.

## Docs

- When a change alters the build, the targets, or the way the app reaches
  a device, update CLAUDE.md in the same change.
