#!/usr/bin/env bash
# Build External Secrets Operator with upstream PR #6989 (DVLS: create the entry on
# push) entirely inside containers.
#
# The source is `git archive` of a committed ref, never the working tree, so a
# stale go.work, go.mod churn from `make go-work`, or untracked files cannot leak
# into the image. The Go builder is golang:<go.mod version>-alpine, as upstream's
# release CI uses, and the runtime is the distroless digest from the ref's
# Dockerfile; both are recorded by digest, and the host Go plays no part. The build
# list then matches the upstream release image module-for-module.
#
# Usage:
#   IMAGE=<registry>/<namespace>/external-secrets ./build-image.sh <ref> <tag> [--push]
#   IMAGE=ghcr.io/example/external-secrets ./build-image.sh build/v2.11.0-dvls v2.11.0-dvls.1
#
# Env:
#   IMAGE                target repository (required)
#   REPO_DIR             ESO clone (default: ./external-secrets next to this script)
#   REGISTRY_USER        with REGISTRY_TOKEN_FILE, log in before pushing;
#   REGISTRY_TOKEN_FILE  otherwise an existing `podman login` is used
#   BUILDER              override the Go builder image; must be digest-pinned
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=${REPO_DIR:-$SCRIPT_DIR/external-secrets}
PLATFORM=linux/amd64

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[[ $# -ge 2 ]] || die "usage: IMAGE=<repository> $0 <ref> <tag> [--push]"
[[ -n ${IMAGE:-} ]] || die "set IMAGE to the target repository, e.g. ghcr.io/example/external-secrets"
REF=$1 TAG=$2 PUSH=false
[[ ${3:-} == --push ]] && PUSH=true
[[ $TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+-[a-z0-9]+\.[0-9]+$ ]] || die "tag must be <upstream-version>-<suffix>.<n>, got '$TAG'"

git -C "$REPO_DIR" rev-parse --verify -q "$REF^{commit}" >/dev/null || die "unknown ref '$REF' in $REPO_DIR"
REVISION=$(git -C "$REPO_DIR" rev-parse "$REF^{commit}")
UPSTREAM=$(git -C "$REPO_DIR" describe --tags --abbrev=0 "$REVISION")
[[ $TAG == "$UPSTREAM"-* ]] || die "tag '$TAG' does not match the ref's upstream base '$UPSTREAM'"

# Upstream's release CI builds with the Go version in go.mod (setup-go go-version-file), not the
# one Dockerfile.standalone pins; those drift apart (v2.11.0: go.mod 1.26.6, standalone 1.27.0).
GO_VERSION=$(git -C "$REPO_DIR" show "$REVISION:go.mod" | awk '$1 == "go" {print $2; exit}')
[[ -n $GO_VERSION ]] || die "no go directive in go.mod at $REVISION"
if [[ -z ${BUILDER:-} ]]; then
  BUILDER=docker.io/library/golang:$GO_VERSION-alpine
  podman pull -q --platform "$PLATFORM" "$BUILDER" >/dev/null
  BUILDER=$BUILDER@$(podman image inspect "$BUILDER" --format '{{.Digest}}')
fi
RUNTIME=$(git -C "$REPO_DIR" show "$REVISION:Dockerfile" | awk '/^FROM/ {print $2; exit}')
[[ $BUILDER == *@sha256:* && $RUNTIME == *@sha256:* ]] || die "base images not digest-pinned: '$BUILDER' / '$RUNTIME'"

if $PUSH; then
  if [[ -n ${REGISTRY_USER:-} && -n ${REGISTRY_TOKEN_FILE:-} ]]; then
    tr -d '\n' <"$REGISTRY_TOKEN_FILE" | podman login "${IMAGE%%/*}" --username "$REGISTRY_USER" --password-stdin
  fi
  # Tags are never moved: a node that cached the old layers under IfNotPresent would keep running them.
  # On a private repository an auth failure looks like a missing tag, so only "manifest unknown" counts.
  if out=$(skopeo inspect --raw "docker://$IMAGE:$TAG" 2>&1); then
    die "$IMAGE:$TAG already exists in the registry; bump the .<n> counter"
  elif ! grep -q 'manifest unknown' <<<"$out"; then
    die "cannot tell whether $IMAGE:$TAG exists (logged in?): $out"
  fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
log "source   $REF @ $REVISION (upstream $UPSTREAM)"
log "builder  $BUILDER"
log "runtime  $RUNTIME"
mkdir "$WORK/src"
git -C "$REPO_DIR" archive "$REVISION" | tar -x -C "$WORK/src"

cat >"$WORK/Containerfile" <<'EOF'
ARG BUILDER
ARG RUNTIME
FROM ${BUILDER} AS builder
# GOWORK=off: the root go.mod replaces every provider module, so no go.work is needed.
# GOTOOLCHAIN=local: fail rather than silently download another Go.
ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOWORK=off GOTOOLCHAIN=local
WORKDIR /src
COPY . .
RUN --mount=type=cache,id=eso-gomod,target=/go/pkg/mod \
    --mount=type=cache,id=eso-gobuild,target=/root/.cache/go-build \
    go mod download && \
    go build -tags all_providers -o /out/external-secrets main.go
# Without -tags all_providers the binary ships with no providers at all; check the patch is linked.
RUN go tool nm /out/external-secrets > /tmp/nm && \
    grep -q 'providers/v1/dvls.*createEntry' /tmp/nm && \
    grep -q 'providers/v1/dvls.*ensureFolderPath' /tmp/nm && \
    go version -m /out/external-secrets | grep -A1 'dep.*providers/v1/dvls' | grep -q '=>.*\./providers/v1/dvls' && \
    echo "providers linked: $(go version -m /out/external-secrets | grep -c 'external-secrets/\(providers\|generators\)/')" && \
    echo "dependencies: $(go version -m /out/external-secrets | grep -c '^\s*dep')"

FROM ${RUNTIME}
COPY --from=builder /out/external-secrets /bin/external-secrets
# Run as UID for nobody
USER 65534
ENTRYPOINT ["/bin/external-secrets"]
EOF

log "building $IMAGE:$TAG"
podman build \
  --platform "$PLATFORM" \
  -f "$WORK/Containerfile" \
  --build-arg BUILDER="$BUILDER" \
  --build-arg RUNTIME="$RUNTIME" \
  --label maintainer="cncf-externalsecretsop-maintainers@lists.cncf.io" \
  --label description="External Secrets Operator is a Kubernetes operator that integrates external secret management systems" \
  --label org.opencontainers.image.title=external-secrets \
  --label org.opencontainers.image.version="$TAG" \
  --label org.opencontainers.image.revision="$REVISION" \
  --label org.opencontainers.image.source=https://github.com/andrey-hdi/eso-dvls \
  --label org.opencontainers.image.base.name="ghcr.io/external-secrets/external-secrets:$UPSTREAM" \
  --label org.opencontainers.image.description="External Secrets Operator $UPSTREAM plus unmerged upstream PR external-secrets/external-secrets#6989 (dvls: create the entry when pushing to a missing remote key). Replace with upstream once #6989 ships." \
  --label eso-dvls.upstream-version="$UPSTREAM" \
  --label eso-dvls.chart-version="${UPSTREAM#v}" \
  --label eso-dvls.patches=external-secrets/external-secrets#6989 \
  --label eso-dvls.builder="$BUILDER" \
  -t "$IMAGE:$TAG" \
  "$WORK/src"

podman run --rm "$IMAGE:$TAG" --help >/dev/null || die "built image does not run"
log "built    $IMAGE:$TAG ($(podman image inspect "$IMAGE:$TAG" --format '{{.Id}}' | cut -c1-12))"

if $PUSH; then
  podman push --digestfile "$WORK/digest" "$IMAGE:$TAG"
  log "pushed   $IMAGE:$TAG@$(cat "$WORK/digest")"
else
  log "not pushed; re-run with --push to publish"
fi
