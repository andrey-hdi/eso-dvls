# eso-dvls

Tooling to build [External Secrets Operator](https://github.com/external-secrets/external-secrets) (ESO) with the unmerged upstream PR [#6989](https://github.com/external-secrets/external-secrets/pull/6989) applied, until that PR ships in an ESO release.

## Why

Upstream, ESO's Devolutions Server (DVLS) provider can only update an existing entry. A `PushSecret` to an entry that does not exist yet fails with `entry must exist before pushing secrets`. With `updatePolicy: IfNotExists`, the push is skipped as soon as the entry exists. So the usual bootstrap pattern (a generator creates a secret, a `PushSecret` seeds the vault, an `ExternalSecret` reads it back) can never write a value. Issue [#6988](https://github.com/external-secrets/external-secrets/issues/6988) describes the problem in full.

PR #6989 makes the provider create the entry when it is missing, including any missing folders along its path. Everything else in the image is stock upstream.

## Contents

| file | purpose |
|---|---|
| [`build-image.sh`](build-image.sh) | builds the image with podman entirely inside containers, verifies it and optionally pushes it |
| [`BUILD.md`](BUILD.md) | the full procedure: prepare a build branch, build, push, check the pull, deploy, retire |

## Quick start

```bash
git clone https://github.com/andrey-hdi/eso-dvls.git && cd eso-dvls
git clone https://github.com/external-secrets/external-secrets.git
(cd external-secrets && git fetch origin pull/6989/head:pr-6989 &&
 git switch -c build/v2.11.0-dvls v2.11.0 &&
 git cherry-pick $(git merge-base pr-6989 origin/main)..pr-6989)
IMAGE=ghcr.io/example/external-secrets ./build-image.sh build/v2.11.0-dvls v2.11.0-dvls.1
```

Add `--push` to publish the image. See [BUILD.md](BUILD.md) before deploying it.

Once #6989 ships upstream, stop using this image and go back to the upstream release.
