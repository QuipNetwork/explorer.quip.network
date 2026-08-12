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

# ── Blockscout cannot parse an underscore in the DB hostname ─────────────────
# Blockscout 9.0.2 pulls the connection parameters out of DATABASE_URL with a
# regex (explorer/repo/config_helper.ex:63) whose hostname class is letters,
# digits, hyphen and dot — there is no underscore in it. Flux's inter-component
# DNS name is ALWAYS flux<component>_<appname>, so the URL never matches,
# Regex.named_captures returns nil, and Keyword.new(nil) raises
#   (Protocol.UndefinedError) protocol Enumerable not implemented for nil
# during repo init — before a socket is ever opened. The failure therefore looks
# exactly like "the database is not up yet" and is not: it is unreachable by
# retrying, and no docker-compose rehearsal can surface it, because a compose
# service name ("bsdb") has no underscore.
#
# Postgrex reads PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE directly and applies
# no such restriction, and ConfigHelper.extract_parameters("") returns [] rather
# than raising — so for a host Blockscout cannot parse we decompose the URL into
# those variables and drop DATABASE_URL. The name (not a resolved address) stays
# in PGHOST, so it is re-resolved on every reconnect and survives bsdb changing
# IP, which a boot-time IP substitution would not.
#
# Only hosts that Blockscout would reject are converted, so DATABASE_URL keeps
# working untouched for the compose harnesses.
db_host_unparseable_by_blockscout() {
    case "$1" in
        *[!A-Za-z0-9.-]*) return 0 ;;
        *)                return 1 ;;
    esac
}

_rest="${DATABASE_URL#*://}"
_creds="${_rest%@*}"          # %/%% from the right: a '@' in the password is safe
_hostetc="${_rest##*@}"
_hostport="${_hostetc%%/*}"
_db="${_hostetc#*/}"; _db="${_db%%\?*}"
_host="${_hostport%%:*}"
_port="${_hostport#*:}"; [ "$_port" = "$_hostport" ] && _port=5432

if db_host_unparseable_by_blockscout "${_host}"; then
    log "DB host '${_host}' is unparseable by Blockscout's DATABASE_URL regex"
    log "  -> supplying PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE instead"
    PGHOST="${_host}"; PGPORT="${_port}"; PGDATABASE="${_db}"
    PGUSER="${_creds%%:*}"; PGPASSWORD="${_creds#*:}"
    export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD
    unset DATABASE_URL
    [ -n "${PGHOST}" ] && [ -n "${PGUSER}" ] && [ -n "${PGDATABASE}" ] || {
        log "ERROR: could not decompose DATABASE_URL into PG* variables"; exit 1; }
fi
unset _rest _creds _hostetc _hostport _db _host _port

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
