#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds the three explorer images for Flux and prints the digests to paste into
# the app spec. Mirrors the bootnodes.quip.network build discipline rather than
# introducing CI: Quip Flux images are built locally and pushed by hand.
#
#   --platform linux/amd64   Quip Flux images are amd64-only. Never multi-arch.
#   --provenance=false
#   --sbom=false             Together these produce a SINGLE-platform manifest
#                            rather than a manifest LIST. That matters: for a
#                            list, `docker image inspect .RepoDigests` reports
#                            the list digest, not the amd64 child, and pinning
#                            the list digest in a Flux spec pins the wrong
#                            object. Single-platform means the digest printed
#                            below IS the image digest.
#   BUILDX_BUILDER=default   The `multiarch` builder has broken DNS in this
#                            environment.
#
# Usage:
#   scripts/build-images.sh            # build only
#   PUSH=1 scripts/build-images.sh     # build and push (needs a registry login)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

REGISTRY="${REGISTRY:-registry.gitlab.com/quip.network/explorer.quip.network}"
TAG_SUFFIX="${TAG_SUFFIX:-$(git rev-parse --short HEAD 2>/dev/null || echo local)}"
PUSH="${PUSH:-}"

log() { printf '[build-images] %s\n' "$*" >&2; }

build_one() {
    local role="$1" tag="${REGISTRY}:${1}-${TAG_SUFFIX}"
    log "building ${tag}"
    BUILDX_BUILDER=default docker build \
        -f "Dockerfile.${role}" \
        --platform linux/amd64 \
        --provenance=false --sbom=false \
        --build-arg BAKE_PROD_ENV=1 \
        -t "${tag}" .
    if [ -n "${PUSH}" ]; then
        log "pushing ${tag}"
        # >&2 is load-bearing: this function returns the tag on STDOUT and the caller
        # captures it with $(...). docker push writes its transcript to stdout too, so
        # without this the captured "tag" is the whole push log and every later use of
        # it — the case match, docker image inspect, the digest lookup — gets garbage.
        docker push "${tag}" >&2
    fi
    printf '%s\n' "${tag}"
}

TAGS=()
for role in api ui proxy; do
    TAGS+=("$(build_one "${role}")")
done

echo
log "built:"
for t in "${TAGS[@]}"; do
    # Assert the bake actually landed. A silently neutral image (built without
    # the build-arg) starts cleanly and then indexes the wrong chain from block
    # 0 — verify the fix is IN the image rather than trusting the tag.
    case "${t}" in
        *:api-*)
            docker image inspect "${t}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                | grep -q '^CHAIN_ID=20033$' || { log "FATAL: ${t} has no baked CHAIN_ID — built without BAKE_PROD_ENV?"; exit 1; }
            docker image inspect "${t}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                | grep -q '^FIRST_BLOCK=985665$' || { log "FATAL: ${t} has no baked FIRST_BLOCK"; exit 1; }
            ;;
        *:ui-*)
            docker image inspect "${t}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                | grep -q '^NEXT_PUBLIC_NETWORK_ID=20033$' || { log "FATAL: ${t} has no baked NEXT_PUBLIC_NETWORK_ID"; exit 1; }
            ;;
        *:proxy-*)
            docker image inspect "${t}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                | grep -q '^PROXY_PORT=20050$' || { log "FATAL: ${t} has no baked PROXY_PORT"; exit 1; }
            ;;
    esac
    if [ -n "${PUSH}" ]; then
        printf '  %s\n    %s\n' "${t}" "$(docker image inspect "${t}" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo '(digest available after push)')"
    else
        printf '  %s\n' "${t}"
    fi
done

[ -n "${PUSH}" ] || log "not pushed (set PUSH=1). Digests are only available after a push."
