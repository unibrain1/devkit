# Site review rules

Reviewers and agents read these rules when they check a change to this
site. Add the rules of this site to each section.

## Site and build

- `npm run build` must pass. Eleventy reads `src/` and writes `_site/`.
- Do not edit or commit a file in `_site/`. The build makes it.
- Each page has a title and a description.
- Each image has alt text.
- CSS files must pass `npm run lint:css` (stylelint).

## PHP

- Each PHP file must pass `npm run lint:php` (`php -l`).
- Escape all output. Validate all user input.
- Do not write a secret in the code. Read it from the host environment.

## Docs

- When a change alters the build or the deploy, update CLAUDE.md in the
  same change.
- Markdown files must pass `npm run lint:md`.
