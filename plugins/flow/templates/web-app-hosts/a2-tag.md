The app runs on A2 Hosting. Two pushes to the deploy remote on the host
deploy a release: the release tag, then the tagged commit to `main`. The
host's post-receive hook checks out the pushed commit. The deploy remote
is not `origin`: do not mix up the two.

To deploy release `vX.Y.Z`:

```sh
git push <deploy-remote> vX.Y.Z
git push <deploy-remote> 'vX.Y.Z^{commit}:refs/heads/main'
```

The second push names `refs/heads/main` in full. A commit is not a
branch, so git cannot find the full name of `main` on a remote that does
not have it yet.

Do not push to the deploy remote without a person's approval.
