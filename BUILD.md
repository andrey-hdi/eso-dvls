# Building the image

How to build External Secrets Operator (ESO) with upstream PR [#6989](https://github.com/external-secrets/external-secrets/pull/6989) applied, push it to your own registry, and deploy it.

## When to rebuild

- the PR gains new commits, for example after review, that should reach your clusters
- you upgrade the ESO Helm chart: the image must be based on the same upstream version as the chart, because the chart ships the CRDs (chart `2.11.0` needs an image based on `v2.11.0`)

## Prerequisites

- podman, skopeo and git. The build runs entirely inside containers, so no local Go toolchain is needed.
- a clone of ESO. By default the script looks for it at `./external-secrets`, next to the script; set `REPO_DIR` to use another path.
- to push: write access to the target repository, via either an existing `podman login` or `REGISTRY_USER` plus `REGISTRY_TOKEN_FILE` (a file containing just the token)

## 1. Prepare a build branch

A build branch is an upstream release tag with the PR's commits cherry-picked onto it. From the root of this repository:

```bash
git clone https://github.com/external-secrets/external-secrets.git
cd external-secrets
git fetch origin pull/6989/head:pr-6989
git switch -c build/v2.11.0-dvls v2.11.0
git cherry-pick $(git merge-base pr-6989 origin/main)..pr-6989
```

If the PR gains commits later, fetch it again and cherry-pick the new commits onto the build branch. The script builds only what is committed on the ref you give it. Uncommitted changes, `go.work` and untracked files are ignored.

## 2. Build and check locally

```bash
IMAGE=ghcr.io/example/external-secrets ./build-image.sh build/v2.11.0-dvls v2.11.0-dvls.1
```

The build fails unless all of the following hold:
- the tag is `<upstream-version>-<suffix>.<n>` and matches the branch's upstream base
- all providers are compiled in (`-tags all_providers`) and the DVLS patch functions `createEntry` / `ensureFolderPath` are in the binary
- the finished image starts

It builds with the Go version from `go.mod`, the same as upstream's release pipeline. For v2.4.1 and v2.11.0 this gives the same Go version and the same module list as the upstream release image; only the DVLS provider source differs.

## 3. Push

```bash
IMAGE=ghcr.io/example/external-secrets ./build-image.sh build/v2.11.0-dvls v2.11.0-dvls.1 --push
```

The script refuses to push a tag that already exists. **Never re-push a tag:** nodes that already cached it keep running the old image under `imagePullPolicy: IfNotPresent`. For every rebuild, increase the counter: `.1` → `.2` → `.3`. The last line of the output shows the pushed digest.

## 4. Check your cluster can pull it

If the repository is private, the nodes need a way to pull it: `imagePullSecrets` on the ESO service accounts, or a registry mirror that authenticates on their behalf. Check before deploying, preferably on every node:

```bash
kubectl run eso-pull-probe --restart=Never --image-pull-policy=Always \
  --image=ghcr.io/example/external-secrets:v2.11.0-dvls.1 \
  --overrides='{"spec":{"nodeName":"<node>"}}' -- --help
```

The pod should reach `Completed`; delete it afterwards. A pull-through cache that has no credentials for the upstream registry usually reports a private image as `not found` rather than `unauthorized`.

## 5. Deploy

Point all three workloads of the upstream chart at the image, keeping the chart version equal to the image's upstream version:

```yaml
image:
  repository: ghcr.io/example/external-secrets
  tag: v2.11.0-dvls.1
webhook:
  image:
    repository: ghcr.io/example/external-secrets
    tag: v2.11.0-dvls.1
certController:
  image:
    repository: ghcr.io/example/external-secrets
    tag: v2.11.0-dvls.1
```

`helm template` with and without these values should differ only in the three `image:` lines. After the rollout, check that:
- the pods run the new digest
- ExternalSecrets are `SecretSynced` and PushSecrets `Synced`
- the operator log has no errors

## Retiring the image

Once #6989 ships in an upstream release:
1. Remove the image overrides and move to that chart version.
2. Delete the build branches.
3. Delete the image tags from your registry.
