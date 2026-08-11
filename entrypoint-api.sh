#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Blockscout backend entrypoint for the Quip explorer (QUI-992).
#
# Why this exists rather than a bare `sh -c "migrate && start"`:
#
# Flux has NO cross-component ordering primitive. There is no depends_on, no
# healthcheck gate — the four components of an app come up together and in no
# guaranteed order. So bsapi will regularly start before bsdb is accepting
# connections, and a plain migrate-then-start would exit non-zero on that first
# attempt. Flux would restart it, so the app would eventually converge, but via
# a crash-loop that is indistinguishable in the dashboard from a real failure.
#
# The wait is done by RETRYING THE MIGRATION ITSELF rather than by probing the
# port first. A TCP probe would need a tool the Blockscout image does not
# reliably ship (no nc, no pg_isready), and more importantly it tests the wrong
# thing: "the port is open" is not "we can authenticate and migrate". Retrying
# the real operation tests the real precondition.
#
# It FAILS CLOSED. After MIGRATE_MAX_ATTEMPTS the script exits non-zero with a
# greppable marker instead of falling through to `start`, because a Blockscout
# that starts against an unmigrated database does not fail — it serves an
# explorer that is subtly and permanently wrong.
set -eu

MIGRATE_MAX_ATTEMPTS="${MIGRATE_MAX_ATTEMPTS:-60}"
MIGRATE_RETRY_SLEEP="${MIGRATE_RETRY_SLEEP:-5}"

log() { printf '[entrypoint-api] %s\n' "$*" >&2; }

: "${DATABASE_URL:?DATABASE_URL is required — the Flux app spec must supply it}"
: "${SECRET_KEY_BASE:?SECRET_KEY_BASE is required — the Flux app spec must supply it}"

attempt=1
while [ "${attempt}" -le "${MIGRATE_MAX_ATTEMPTS}" ]; do
    if bin/blockscout eval 'Elixir.Explorer.ReleaseTasks.create_and_migrate()'; then
        log "migration OK on attempt ${attempt}"
        break
    fi
    if [ "${attempt}" -eq "${MIGRATE_MAX_ATTEMPTS}" ]; then
        log "ERROR: EXPLORER-MIGRATE-FAILED after ${attempt} attempts"
        log "  Refusing to start the backend against an unmigrated database."
        log "  Check that bsdb is running and that DATABASE_URL points at it"
        log "  (expected host: fluxbsdb_quipexplorer)."
        exit 1
    fi
    log "migration attempt ${attempt}/${MIGRATE_MAX_ATTEMPTS} failed (bsdb not ready?), retrying in ${MIGRATE_RETRY_SLEEP}s"
    attempt=$(( attempt + 1 ))
    sleep "${MIGRATE_RETRY_SLEEP}"
done

log "starting blockscout"
exec bin/blockscout start
