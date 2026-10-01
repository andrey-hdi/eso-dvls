# Building the image

How to build External Secrets Operator (ESO) with the unmerged upstream DVLS provider PRs [#6989](https://github.com/external-secrets/external-secrets/pull/6989) and, optionally, [#7055](https://github.com/external-secrets/external-secrets/pull/7055) applied, push it to your own registry, and deploy it. See the [README](README.md) for what each PR changes.

## When to rebuild

- a PR gains new commits, for example after review, that should reach your clusters
- you want to add #7055 to an image that carries only #6989
- you upgrade the ESO Helm chart: the image must be based on the same upstream version as the chart, because the chart ships the CRDs (chart `2.11.0` needs an image based on `v2.11.0`)

## Prerequisites

- podman, skopeo and git. The build runs entirely inside containers, so no local Go toolchain is needed.
- a clone of ESO. By default the script looks for it at `./external-secrets`, next to the script; set `REPO_DIR` to use another path.
- to push: write access to the target repository, via either an existing `podman login` or `REGISTRY_TOKEN_FILE`. The token file holds either just the token, or two lines `user: …` and `token: …`. With a bare token, also set `REGISTRY_USER`.

## 1. Prepare a build branch

A build branch is an upstream release tag with the PR commits cherry-picked onto it. #7055 is stacked on #6989, so its PR branch holds the commits of both. From the root of this repository:

```bash
git clone https://github.com/external-secrets/external-secrets.git
cd external-secrets
PR=7055   # or 6989 for #6989 alone
git fetch origin pull/$PR/head:pr-$PR
git switch -c build/v2.11.0-dvls v2.11.0
git cherry-pick $(git merge-base pr-$PR origin/main)..pr-$PR
```

To add #7055 to an existing #6989 build branch, fetch both PRs and cherry-pick only the commits #7055 adds: `git cherry-pick pr-6989..pr-7055`.

If a PR gains commits later, fetch it again and cherry-pick the new commits onto the build branch. The script builds only what is committed on the ref you give it. Uncommitted changes, `go.work` and untracked files are ignored.

## 2. Build and check locally

```bash
IMAGE=ghcr.io/example/external-secrets ./build-image.sh build/v2.11.0-dvls v2.11.0-dvls.1
```

The script reads which PRs the branch carries from its source, prints them on the `patches` line, and records them in the image labels (`eso-dvls.patches` and the description). There is nothing to configure. The build fails unless all of the following hold:
- the tag is `<upstream-version>-<suffix>.<n>` and matches the branch's upstream base
- the branch carries #6989, and each PR is either complete or absent. A branch with only some of a PR's commits is refused.
- the upstream base does not already contain a PR's functions. If it does, that PR has shipped, and the image may no longer be needed.
- all providers are compiled in (`-tags all_providers`), and the functions each PR adds are in the binary: `createEntry` / `ensureFolderPath` for #6989, and `clearField` / `pushField` / `setCredentialField` for #7055
- the finished image starts

It builds with the Go version from `go.mod`, the same as upstream's release pipeline. For v2.4.1 and v2.11.0 this gives the same Go version and the same module list as the upstream release image; only the DVLS provider source differs. The binary is reproducible: building the same commit again gives a byte-identical `/bin/external-secrets`. Only the labels can differ between two builds, so compare the binaries, not the image digests.

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

### First rollout of #7055: entries that earlier pushes got wrong

Without #7055, the provider ignores `remoteRef.property` and writes every item into the password. So a `PushSecret` that pushes a `username` and a `password` item to the same remote key may already have stored the username as the password. On an image with #6989 alone, the entry it created is a `Credential/AccessCode`, which has no username field.

#7055 does not repair such entries. On an `AccessCode` entry the push now fails with `entry "<name>" is Credential/AccessCode, which has no username field`, and the entry is left as it is. Under `updatePolicy: IfNotExists`, a `Credential/Default` entry whose password holds the username is not rewritten either, because both fields are already set.

Before rolling out, list the PushSecrets that set `remoteRef.property` to `username` or `domain`, and check the entries they write. Delete each broken entry in DVLS after the rollout; the ESO identity usually has no Delete right, so a signed-in user has to do it. The next push re-creates it as `Credential/Default` with both fields. To push at once instead of waiting for `refreshInterval`, add any annotation to the PushSecret: a change to its labels or annotations forces a push.

## Retiring the image

Once the PRs ship in an upstream release:
1. Remove the image overrides and move to that chart version.
2. Delete the build branches.
3. Delete the image tags from your registry.

If only #6989 ships, the script refuses to build on that release, because the upstream base already has #6989's functions. Keep the image only if you still need #7055, and update the script for it.
