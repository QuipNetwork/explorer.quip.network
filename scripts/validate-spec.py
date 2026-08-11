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

failures = []
checks = 0


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
        chk(len(c["commands"]) <= 20, f"{n}: max 20 commands")
        for cmd in c["commands"]:
            chk(len(cmd) <= 400, f"{n}: command over 400 chars")
        chk(len(c["description"]) <= 256, f"{n}: description <= 256 chars")
        chk(len(c["repotag"]) <= 200, f"{n}: repotag <= 200 chars")
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
    print(f"\nTOTALS  cpu={tot_cpu}  ram={tot_ram} MB  hdd={tot_hdd} GB  "
          f"instances={instances}  staticip={staticip}")

    discount = instances < 4 and tot_cpu < 3 and tot_ram < 6000 and tot_hdd < 150
    raw = (tot_cpu * 0.15 * 10) + (tot_ram * 0.05 / 100) + (tot_hdd * 0.02) \
        + (2.0 if staticip else 0.0) + (ent_count * 2.0)
    per = math.ceil(raw / 3)
    est = per * instances * (0.8 if discount else 1.0)
    print(f"0.8x discount (instances<4, cpu<3, ram<6000, hdd<150): {discount}")
    print(f"price estimate ~= {est:.2f}/month  (raw={raw:.3f}, perInstance=ceil({raw/3:.3f})={per})")
    if not discount and tot_cpu >= 3:
        print(f"HINT: cpu total is {tot_cpu}; dropping below 3.0 would apply the 0.8x multiplier")
    print("The dashboard calculator is authoritative — confirm there before subscribing.")

    print(f"\n{checks - len(failures)}/{checks} checks passed")
    if failures:
        print(f"{len(failures)} FAILURE(S)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SPEC))
