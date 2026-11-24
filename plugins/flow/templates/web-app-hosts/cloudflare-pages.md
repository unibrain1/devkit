Cloudflare Pages deploys `main` through its Git integration. Cloudflare
builds each push to `main` and serves the result. Cloudflare also makes a
preview for each PR branch.

A merge to `main` is a deploy: merge to `main` only at a release.
