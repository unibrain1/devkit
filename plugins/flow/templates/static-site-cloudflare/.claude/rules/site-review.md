# Site review rules

Reviewers and agents read these rules when they check a change to this
site. Add the rules of this site to each section.

## Site and build

- `npm run build` must pass. Eleventy reads `src/` and writes `_site/`.
- Do not edit or commit a file in `_site/`. The build makes it.
- Each page has a title and a description.
- Each image has alt text.

## Pages Functions (optional)

Use this section only when the site has a `functions/` folder.

- CI compiles the functions when `ci.yml` sets `pages_functions: true`.
- Read each secret from the Cloudflare environment. Do not write a secret
  in the code.

## Docs

- When a change alters the build or the deploy, update CLAUDE.md in the
  same change.
- Markdown files must pass `npm run lint`.
