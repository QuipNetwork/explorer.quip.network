#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""
Offline validator for the Quip explorer Flux v8 app spec (QUI-992).

Why this exists: Flux's own `verifyappupdatespecifications` endpoint is BLIND on
enterprise apps — it returns success for anything — and the dashboard surfaces a
validation failure only after you have filled in the whole wizard. The rules
below are transcribed from FluxOS's appValidator.js and config/default.js, so a
spec that passes here has already cleared the checks that would otherwise reject
it late.

It also prints the price estimate, including whether the spec sits on the right
side of the 0.8x discount cliff.

This does NOT replace the dashboard: the calculator there is authoritative for
price, and the dashboard export is the canonical spec. This catches the
mechanical errors before you get that far.

Usage: scripts/validate-spec.py [path-to-spec.json]
"""
import json
import math
import sys
from pathlib import Path

DEFAULT_SPEC = Path(__file__).resolve().parent.parent / "deploy" / "flux" / "explorer-app-spec.json"

# config/default.js: banned port ranges (inclusive) and singletons
BANNED_RANGES = [(16100, 16299), (26100, 26299), (30000, 30099)]
BANNED_PORTS = {22, 23, 25, 53, 123, 161, 512, 513, 3388, 3389, 4444, 5800, 5900, 5901, 8384, 27017}
# config/default.js enterprisePorts — legal, but each adds a surcharge pre-divisor
ENTERPRISE_PORTS = set(range(0, 1024)) | {8080, 8081, 8443, 6667}

# Live USD rate table: https://stats.runonflux.io/apps/getappspecsusdprice — which is the URL
# FluxOS itself fetches (appSpecHelpers.js:355), falling back to config.fluxapps.usdprice. Note
# these are NOT the config.fluxapps.price fork values, and they are NOT what Flux's own docs quote
# (the docs say enterprise $0.80 / staticip $0.40; the live table charges 4 and 2). The oracle wins.
RATE_CPU, RATE_RAM, RATE_HDD = 0.15, 0.05, 0.02
RATE_SCOPE, RATE_STATICIP, RATE_PORT = 4.0, 2.0, 2.0

def repotag_has_tag(repotag):
    """FluxOS requires a :TAG on every repotag, even when the image is digest-pinned.

    ImageVerifier.imagePattern (imageVerifier.js:14) parses only
    [HOST[:PORT]/][NAMESPACE/]REPOSITORY[:TAG] — there is no '@sha256:' branch anywhere in
    it. Given a bare `postgres@sha256:...` it parses namespace='postgres', repository='',
    tag=undefined and the registry lookup then fails with "Authentication failed: ... not
    available or doesn't exist", which reads like a credentials problem and is not one.

    The working form is `repo:TAG@sha256:DIGEST`: the regex's tag group stops at '@' (which
    is outside its [\\w.-] class) and the unmatched digest tail is ignored by the parser,
    while Docker still honours the digest on pull. 1049 of 1050 live Flux repotags carry a
    plain :TAG; the sole digest-pinned one uses exactly this tag@digest form.
    """
    base = repotag.split("@", 1)[0]      # drop any digest suffix
    last = base.rsplit("/", 1)[-1]       # only the final path segment can hold the tag
    return ":" in last and last.split(":", 1)[1] != ""


failures = []
checks = 0


def app_price(cpu, ram, hdd, instances, staticip, enterprise, ent_ports):
    """Reproduce FluxOS's monthly USD price — appUtilities.js:112-140 + appSpecHelpers.js:426-434.

    The rounding is the part that is easy to get wrong: FluxOS ceilings to CENTS
    (`Math.ceil(x * 100) / 100`), not to whole dollars. An integer ceil overstates this spec by
    ~$0.40. Verified to the cent against POST /apps/calculatefiatandfluxprice on three arms
    (as-specced 2.78, staticip off 2.26, hdd 150 -> 3.44).
    """
    total = (cpu * RATE_CPU * 10) + (ram * RATE_RAM / 100) + (hdd * RATE_HDD)
    if enterprise:
        total += RATE_SCOPE          # `scope`: enterprise/encrypted, or node-targeted
    if staticip:
        total += RATE_STATICIP
    total += ent_ports * RATE_PORT

    price = math.ceil(total / 3 * 100) / 100          # base is ALWAYS total/3, ceiled to cents
    extra = instances - 1
    if extra > 0:
        if price < 0.50 and extra > 2:
            price += extra * 0.50
        else:
            price = (math.ceil(price * extra * 100) + math.ceil(price * 100)) / 100

    if instances < 4:                                  # applyHWDiscount
        if cpu < 3 and ram < 6000 and hdd < 150:
            price *= 0.8
        elif cpu < 7 and ram < 29000 and hdd < 370:
            price *= 0.9
    return price


def chk(cond, msg):
    global checks
    checks += 1
    if not cond:
        failures.append(msg)
        print(f"FAIL: {msg}")


def main(path):
    spec = json.loads(Path(path).read_text())

    chk(spec.get("version") == 8, "version must be 8")
    name = spec.get("name", "")
    chk(name.isalnum(), f"app name {name!r} must be alphanumeric")
    chk(not name.lower().startswith(("flux", "zel")), f"app name {name!r} must not start with flux/zel")
    chk(len(name) <= 63, "app name <= 63 chars (v8)")
    chk(1 <= len(spec.get("compose", [])) <= 10, "compose must hold 1-10 components")

    seen, all_ports = set(), []
    tot_cpu = tot_ram = tot_hdd = 0.0

    for c in spec["compose"]:
        n = c["name"]
        chk(n.isalnum(), f"{n}: component name must be alphanumeric (no - or _)")
        chk(len(n) >= 3, f"{n}: component name >= 3 chars")
        chk(not n.lower().startswith(("flux", "zel")), f"{n}: must not start with flux/zel")
        chk(n not in seen, f"{n}: component names must be unique")
        seen.add(n)

        chk(len(c["ports"]) == len(c["domains"]) == len(c["containerPorts"]),
            f"{n}: ports/domains/containerPorts must be equal length "
            f"({len(c['ports'])}/{len(c['domains'])}/{len(c['containerPorts'])})")
        chk(len(c["ports"]) <= 5, f"{n}: max 5 ports per component")
        chk(2 <= len(c["containerData"]) <= 200, f"{n}: containerData length must be 2-200")
        chk(len(c["environmentParameters"]) <= 20,
            f"{n}: {len(c['environmentParameters'])} env vars exceeds the hard cap of 20 "
            "(cleartext + encrypted secrets COMBINED)")
        for e in c["environmentParameters"]:
            chk(len(e) <= 400, f"{n}: env entry over 400 chars: {e[:40]}...")
            chk("=" in e and e.split("=", 1)[1] != "", f"{n}: env value must not be empty: {e[:40]}")
            # A forgotten <REPLACE> is non-empty, so the emptiness check above sails past it
            # and the spec deploys with a literal placeholder as the Postgres password.
            chk("<REPLACE" not in e,
                f"{n}: env value is still a placeholder: {e.split('=', 1)[0]}=<REPLACE...>")
        chk(len(c["commands"]) <= 20, f"{n}: max 20 commands")
        for cmd in c["commands"]:
            chk(len(cmd) <= 400, f"{n}: command over 400 chars")
        chk(len(c["description"]) <= 256, f"{n}: description <= 256 chars")
        chk(len(c["repotag"]) <= 200, f"{n}: repotag <= 200 chars")
        if "<REPLACE" in c["repotag"]:
            chk(False, f"{n}: repotag is still the placeholder {c['repotag']} — fill it "
                       "with repo:TAG@sha256:DIGEST before deploying")
        else:
            chk(repotag_has_tag(c["repotag"]),
                f"{n}: repotag has no :TAG — {c['repotag'][:70]}. FluxOS cannot parse a bare "
                "digest reference; use repo:TAG@sha256:DIGEST (see repotag_has_tag)")
        for d in c["domains"]:
            chk(len(d) <= 253, f"{n}: domain entry <= 253 chars")

        all_ports += c["ports"]
        tot_cpu += c["cpu"]
        tot_ram += c["ram"]
        tot_hdd += c["hdd"]

    chk(len(all_ports) == len(set(all_ports)), "ports must be unique across ALL components")
    ent_count = 0
    for p in all_ports:
        chk(1 <= p <= 65535, f"port {p} out of range")
        banned = p in BANNED_PORTS or any(lo <= p <= hi for lo, hi in BANNED_RANGES)
        chk(not banned, f"port {p} is in FluxOS's banned list")
        if p in ENTERPRISE_PORTS:
            ent_count += 1
            print(f"NOTE: port {p} is an enterprise port — adds a surcharge before the price divisor")

    instances = spec.get("instances", 1)
    staticip = bool(spec.get("staticip"))
    enterprise = bool(spec.get("enterprise")) or bool(spec.get("nodes"))
    print(f"\nTOTALS  cpu={tot_cpu}  ram={tot_ram} MB  hdd={tot_hdd} GB  "
          f"instances={instances}  staticip={staticip}  enterprise={enterprise}")

    for label, ent in (("plain", False), ("enterprise", True)):
        price = app_price(tot_cpu, tot_ram, tot_hdd, instances, staticip, ent, ent_count)
        mark = "  <-- this spec" if ent == enterprise else ""
        print(f"price {label:10s} ~= {price:.2f}/month{mark}")
    print("Paying in FLUX takes a further 5% off (fluxDiscount).")
    print("The dashboard calculator is authoritative — confirm there before subscribing.")

    print(f"\n{checks - len(failures)}/{checks} checks passed")
    if failures:
        print(f"{len(failures)} FAILURE(S)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SPEC))
