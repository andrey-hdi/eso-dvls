# eso-dvls

Tooling to build [External Secrets Operator](https://github.com/external-secrets/external-secrets) (ESO) with unmerged upstream fixes to its Devolutions Server (DVLS) provider, until they ship in an ESO release.

## Why

| PR | issue | what it changes |
|---|---|---|
| [#6989](https://github.com/external-secrets/external-secrets/pull/6989) | [#6988](https://github.com/external-secrets/external-secrets/issues/6988) | `PushSecret` creates a missing entry, including any missing folders along its path |
| [#7055](https://github.com/external-secrets/external-secrets/pull/7055) | [#7054](https://github.com/external-secrets/external-secrets/issues/7054) | `PushSecret` writes the field that `remoteRef.property` names: `username`, `password` or `domain`. Stacked on #6989 |

Upstream, the provider can only update an existing entry. A `PushSecret` to an entry that does not exist yet fails with `entry must exist before pushing secrets`, and with `updatePolicy: IfNotExists` the push is skipped as soon as the entry exists. So the usual bootstrap pattern (a generator creates a secret, a `PushSecret` seeds the vault, an `ExternalSecret` reads it back) can never write a value. #6989 fixes that.

Upstream also ignores `remoteRef.property` on push: every value goes into the entry's password, without a warning. A `PushSecret` that pushes a username and a password to the same entry can leave the username in the password field. #7055 writes each value to the field its property names, creates the entry as a `Credential/Default` (which has a username field) when a property is set, and refuses a property it cannot write.

The image carries #6989 alone or #6989 plus #7055, depending on the build branch. Everything else is stock upstream.

## Contents

| file | purpose |
|---|---|
| [`build-image.sh`](build-image.sh) | builds the image with podman entirely inside containers, verifies it and optionally pushes it |
| [`BUILD.md`](BUILD.md) | the full procedure: prepare a build branch, build, push, check the pull, deploy, retire |

## Quick start

With both PRs (the #7055 branch contains the commits of #6989):

```bash
git clone https://github.com/andrey-hdi/eso-dvls.git && cd eso-dvls
git clone https://github.com/external-secrets/external-secrets.git
(cd external-secrets && git fetch origin pull/7055/head:pr-7055 &&
 git switch -c build/v2.11.0-dvls v2.11.0 &&
 git cherry-pick $(git merge-base pr-7055 origin/main)..pr-7055)
IMAGE=ghcr.io/example/external-secrets ./build-image.sh build/v2.11.0-dvls v2.11.0-dvls.1
```

For #6989 alone, use `pull/6989/head` and `pr-6989` instead. The script works out which of the two PRs the branch carries and labels the image with them.

Add `--push` to publish the image. See [BUILD.md](BUILD.md) before deploying it.

Once the PRs ship upstream, stop using this image and go back to the upstream release.
