#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Renders nginx-explorer.conf.template into the real nginx.conf at container
# start. Run by the stock nginx image entrypoint, which execs everything in
# /docker-entrypoint.d/ in lexical order before starting nginx.
#
# The stock 20-envsubst-on-templates.sh cannot do this job: it renders
# /etc/nginx/templates/*.template into /etc/nginx/conf.d/ as HTTP-block
# fragments, and our template is a COMPLETE nginx.conf (it sets worker_processes
# and opens its own events{} and http{} blocks) precisely so the worker count can
# be pinned. A Flux container sees the host's full core count via nproc, so the
# stock config's `worker_processes auto` would spawn ~56 workers inside a 0.5-cpu
# allocation.
#
# FAILS CLOSED. Every token is asserted before substitution, because envsubst's
# behaviour for an unset variable is to emit an empty string: a missing
# PROXY_PORT would render `listen ;` (nginx refuses to start — loud, fine), but a
# missing BSAPI_UPSTREAM renders `server ;` which is ALSO a config error, and a
# subtly wrong value renders a proxy that starts cleanly and 502s every API call.
# Better to refuse at boot with a named cause.
set -eu

log() { printf '[10-render-explorer-conf] %s\n' "$*" >&2; }

TEMPLATE=/etc/nginx/explorer.conf.template
TARGET=/etc/nginx/nginx.conf

for var in PROXY_PORT BSAPI_UPSTREAM BSUI_UPSTREAM; do
    eval "val=\${${var}:-}"
    if [ -z "${val}" ]; then
        log "ERROR: EXPLORER-PROXY-CONFIG-FAILED — ${var} is unset or empty."
        log "  Build the image with --build-arg BAKE_PROD_ENV=1, or set ${var}"
        log "  explicitly in the app spec. Refusing to render a broken config."
        exit 1
    fi
done

# Substitute ONLY our three tokens. Naming them explicitly is what keeps nginx's
# own runtime variables ($http_upgrade, $connection_upgrade, $remote_addr,
# $proxy_add_x_forwarded_for) from being eaten as if they were shell variables.
envsubst '${PROXY_PORT} ${BSAPI_UPSTREAM} ${BSUI_UPSTREAM}' <"${TEMPLATE}" >"${TARGET}"

log "rendered ${TARGET} (port=${PROXY_PORT} api=${BSAPI_UPSTREAM} ui=${BSUI_UPSTREAM})"

# Catch a malformed render here, at boot, with nginx's own parser naming the
# line — rather than letting the stock entrypoint exec nginx and having it die
# with the same message buried under everything else.
nginx -t
