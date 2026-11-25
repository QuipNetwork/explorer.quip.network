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
# Blockscout itself is built from source first (QUI-2535). Upstream stopped
# publishing public images after backend 9.0.2 and frontend v2.3.5, on purpose
# (blockscout#13226, #14381). So both bases come from upstream's own
# Dockerfiles at the commits pinned below, tagged locally, and our three images
# are built FROM them. Only our images are pushed; they carry every base layer.
# A base already built at the same pinned commit is reused; REBUILD_BASES=1
# forces a rebuild (the backend took 3m40s on 22 cores, 2026-11-25).
#
# Usage:
#   scripts/build-images.sh                  # build only
#   PUSH=1 scripts/build-images.sh           # build and push (needs a registry login)
#   REBUILD_BASES=1 scripts/build-images.sh  # rebuild the upstream bases too
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

REGISTRY="${REGISTRY:-registry.gitlab.com/quip.network/explorer.quip.network}"
TAG_SUFFIX="${TAG_SUFFIX:-$(git rev-parse --short HEAD 2>/dev/null || echo local)}"
PUSH="${PUSH:-}"

log() { printf '[build-images] %s\n' "$*" >&2; }

# ── Upstream, pinned by commit. Bump these together, then rehearse. ─────────
BLOCKSCOUT_REF="066e39b5a3ddeb33a7db102c40e329c0a2990c8e"   # tag v12.1.0
BLOCKSCOUT_VERSION="12.1.0"
FRONTEND_REF="d3cfa7abef62f0409d89898fd39866d7c576ff25"     # tag v2.13.0
FRONTEND_VERSION="v2.13.0"
BACKEND_BASE="local/blockscout-backend:${BLOCKSCOUT_VERSION}-${BLOCKSCOUT_REF:0:8}"
FRONTEND_BASE="local/blockscout-frontend:${FRONTEND_VERSION}-${FRONTEND_REF:0:8}"

build_base() { # TAG CONTEXT [docker build args...]
    local tag="$1" ctx="$2"
    shift 2
    if [ -z "${REBUILD_BASES:-}" ] && docker image inspect "${tag}" >/dev/null 2>&1; then
        log "reusing ${tag} (REBUILD_BASES=1 to rebuild)"
        return
    fi
    log "building ${tag} from ${ctx}"
    BUILDX_BUILDER=default docker build --platform linux/amd64 \
        --provenance=false --sbom=false "$@" -t "${tag}" "${ctx}" >&2
}

# RELEASE_VERSION must equal the release's version: the image copies a file to
# /app/releases/${RELEASE_VERSION}/. BLOCKSCOUT_VERSION is what the API reports
# at /api/v2/config/backend-version. CHAIN_TYPE stays unset: a plain EVM chain.
build_base "${BACKEND_BASE}" "https://github.com/blockscout/blockscout.git#${BLOCKSCOUT_REF}" \
    -f docker/Dockerfile \
    --build-arg "RELEASE_VERSION=${BLOCKSCOUT_VERSION}" \
    --build-arg "BLOCKSCOUT_VERSION=v${BLOCKSCOUT_VERSION}"
build_base "${FRONTEND_BASE}" "https://github.com/blockscout/frontend.git#${FRONTEND_REF}" \
    --build-arg "GIT_COMMIT_SHA=${FRONTEND_REF:0:8}" \
    --build-arg "GIT_TAG=${FRONTEND_VERSION}"

build_one() {
    local role="$1" tag="${REGISTRY}:${1}-${TAG_SUFFIX}" base_args=()
    case "${role}" in
        api) base_args=(--build-arg "BLOCKSCOUT_IMAGE=${BACKEND_BASE}") ;;
        ui)  base_args=(--build-arg "BLOCKSCOUT_FRONTEND_IMAGE=${FRONTEND_BASE}") ;;
    esac
    log "building ${tag}"
    BUILDX_BUILDER=default docker build \
        -f "Dockerfile.${role}" \
        --platform linux/amd64 \
        --provenance=false --sbom=false \
        --build-arg BAKE_PROD_ENV=1 \
        "${base_args[@]}" \
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
                | grep -q '^FIRST_BLOCK=0$' || { log "FATAL: ${t} has no baked FIRST_BLOCK"; exit 1; }
            # Pointing at the RETIRED endpoint is as fatal as a wrong FIRST_BLOCK
            # and was previously unasserted. It also carries more weight now:
            # FIRST_BLOCK is legitimately 0 on aglais, so that check no longer
            # distinguishes a neutral build by VALUE (it still catches an EMPTY
            # one, which is what a missing build-arg produces). This is the assert
            # that catches an image pointed at the wrong chain.
            docker image inspect "${t}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                | grep -q '^ETHEREUM_JSONRPC_HTTP_URL=https://evm-rpc\.aglais\.quip\.network:20049/$' \
                || { log "FATAL: ${t} is not pointed at the aglais EVM RPC"; exit 1; }
            # 12.x tries TLS to Postgres unless ECTO_SSL_MODE says otherwise, and
            # ignores the ECTO_USE_SSL that 9.0.2 needed (QUI-2535).
            docker image inspect "${t}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                | grep -q '^ECTO_SSL_MODE=disable$' || { log "FATAL: ${t} has no baked ECTO_SSL_MODE=disable"; exit 1; }
            docker image inspect "${t}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                | grep -q "^BLOCKSCOUT_VERSION=v${BLOCKSCOUT_VERSION}\$" \
                || { log "FATAL: ${t} is not built on Blockscout v${BLOCKSCOUT_VERSION}"; exit 1; }
            ;;
        *:ui-*)
            docker image inspect "${t}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                | grep -q '^NEXT_PUBLIC_NETWORK_ID=20033$' || { log "FATAL: ${t} has no baked NEXT_PUBLIC_NETWORK_ID"; exit 1; }
            # node 24.21.0's own roots are not fixed; it must verify through the
            # fixed OS bundle (QUI-1930).
            docker image inspect "${t}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                | grep -q '^NODE_OPTIONS=--use-openssl-ca$' || { log "FATAL: ${t} does not set NODE_OPTIONS=--use-openssl-ca"; exit 1; }
            ;;
        *:proxy-*)
            docker image inspect "${t}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                | grep -q '^PROXY_PORT=20050$' || { log "FATAL: ${t} has no baked PROXY_PORT"; exit 1; }
            ;;
    esac
    if [ -n "${PUSH}" ]; then
        # Select the RepoDigest belonging to THIS registry rather than trusting
        # `index .RepoDigests 0`. An image ID that also carries a local tag (a
        # test build, a preview harness) accumulates several RepoDigests, and
        # index 0 is then whichever repository Docker happens to list first —
        # a digest for a different repository, printed as if it were ours.
        digest="$(docker image inspect "${t}" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
                  | grep "^${REGISTRY}@" | head -1)"
        printf '  %s\n    %s\n' "${t}" "${digest:-(digest unavailable — did the push succeed?)}"
    else
        printf '  %s\n' "${t}"
    fi
done

[ -n "${PUSH}" ] || log "not pushed (set PUSH=1). Digests are only available after a push."
