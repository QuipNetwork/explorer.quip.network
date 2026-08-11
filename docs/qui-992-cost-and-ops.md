# QUI-992 — cost, resource shape and operations

The acceptance-criteria record for hosting Blockscout at a public URL, plus the deploy runbook.

Everything numeric here is **measured**, not taken from upstream. Blockscout publishes 16-core /
128 GB / 4 TB sizing that describes Ethereum mainnet; this chain's EVM history is ~107k mostly-empty
blocks and behaves nothing like it.

---

## 1. What was decided, and why

| Question | Answer |
|---|---|
| Depends on metadata v16? | **No.** !65 branches off `ad1321f` only because that is where Roman was working. Blockscout speaks `eth_*` JSON-RPC and never touches Substrate metadata. Startable against the live chain today. |
| Host | **Flux**, raw-Docker, 4 components, 1 instance |
| Why not Akash | AC #5. Akash provider SNAT means a lease's egress IP ≠ its ingress IP, so dnsimple-certifier's caller-IP check 403s in-lease. `statusdb` has been hand-renewed once already and is due again in late October. Manual renewal is the thing AC #5 forbids. |
| Why not Orbit | Flux's own Orbit docs put PostgreSQL under "What Should NOT Be Deployed" and state Orbit is for stateless apps with data stored externally. Orbit also builds one app from one git repo via a buildpack — this deployment composes three prebuilt upstream images — and exposes no volume knob. |
| Why not node08 | It is one of exactly three GRANDPA authorities and a known SPOF. A chunky indexer does not belong on it. |
| Domain / TLS | `explorer.testnet.quip.network`, **FDM custom domain** with Flux-managed Let's Encrypt |
| RPC | The existing `evm-rpc.testnet.quip.network:20049` (QUI-966). Confirmed by probe, not assumed. |

---

## 2. Chain facts the deployment is built on

Probed against the live endpoint on 2026-08-11:

| Probe | Result |
|---|---|
| `eth_chainId` | `0x4e41` = **20033** |
| `net_version` | `20033` |
| `web3_clientVersion` | `eth-rpc/HEAD-f17113f/x86_64-unknown-linux-gnu/rustc1.95.0` |
| `eth_syncing` | `false` |
| lowest resolvable block | **985,665** — 985,664 returns `null` |
| `trace_block` | `Method not found` |
| `debug_traceBlockByNumber` | `[]` |
| WS upgrade on :20049 | `101 Switching Protocols`, JSON-RPC over WS works |
| `eth_subscribe` (over WS) | **`Method not found`** — no pubsub |
| block time | ~6.0 s (~14,300 blocks/day) |

Two consequences that shaped the whole configuration:

- **`FIRST_BLOCK=985665` is mandatory.** Blockscout's catchup fetcher defaults to block 0, and every
  block below 985,665 returns `null`. Without it the indexer grinds on ~985k requests that can never
  resolve and never reaches a complete index. This is baked into the image, not left to the spec.
- **`ETHEREUM_JSONRPC_VARIANT=anvil` is accurate, not a workaround.** The sidecar serves `eth_*` only,
  so internal transactions and block rewards are genuinely unavailable from this endpoint. The
  internal- and pending-transaction fetchers are disabled to match; leaving them on produces an
  endlessly retrying fetcher, not more data.

A third finding, worth knowing before anyone "fixes" it: **the WebSocket carries JSON-RPC but not
pubsub.** The upgrade succeeds and `eth_chainId` answers over WS, but `eth_subscribe` returns
`Method not found` — matching the `bootnodes.quip.network` README's note that eth-rpc has no filter
API and no pubsub. Blockscout treats a WS new-heads subscription as optional and polls
`eth_blockNumber` instead.

**`ETHEREUM_JSONRPC_WS_URL` is therefore not set at all**, rather than set-and-inert. That was
tested, not assumed: the backend was recreated with the variable fully unset (0 occurrences in the
container env) and the realtime fetcher stayed **0–1 blocks behind head across four minutes**, with
zero websocket errors logged — identical behaviour to running with it set. Realtime indexing works;
it works by polling.

The endpoint is already correct for archival indexing: the node runs `--state-pruning=archive
--blocks-pruning=archive` and the sidecar deliberately omits `--eth-pruning`
(`bootnodes.quip.network/deploy/flux/evmrpc-bootstrap.sh`).

---

## 3. Measured resource shape

From the rehearsal (`docker-compose.rehearsal.yml`) run against the live endpoint, backfilling
~107k blocks:

| Component | Measured peak RSS | Measured CPU | Allocated cpu / ram / hdd | Headroom |
|---|---|---|---|---|
| `bsapi` (backend) | 472 MiB | 0.2–0.55 core | 1.25 / 2000 MB / 1 GB | 4.2× |
| `bsdb` (Postgres) | 469 MiB | 1–7% | 0.75 / 1500 MB / **100 GB** | 3.2× |
| `bsui` (frontend) | 186 MiB | idle | 0.5 / 700 MB / 1 GB | 3.8× |
| `bsproxy` (nginx) | 10 MiB | idle | 0.25 / 300 MB / 1 GB | nginx floor |
| **Total** | | | **2.75 cpu / 4500 MB / 103 GB** | |

The run completed: **108,790 blocks indexed in 7,038 s (117 min)**, `finished_indexing: true`,
`indexed_blocks_ratio: 1.00`. The index is exactly `min=985665, max=1094454, count=108790` — which
is precisely `max − min + 1`, i.e. **zero gaps**, and the floor lands exactly on `FIRST_BLOCK`.

Database at head: **136 MiB**, or **1,313 bytes/block** → **~6.4 GiB/year** at the current
near-empty block profile.

**Backfill rate is not constant, and the deploy should budget ~2 hours rather than 80 minutes.**
It held 22–23 blocks/s for the first ~4,000 s (through ~88k blocks) and then stepped down roughly 5×,
recovering to 7–8.5 blocks/s for the remainder. Two things were ruled out: neither container was
saturated (backend CPU *halved* at the transition and Postgres stayed near-idle, so this was waiting
on I/O, not compute), and block depth is not the cause — a follow-up latency probe found
`eth_getBlockByNumber` flat at 0.63–0.69 s from head all the way down to the EVM floor, with
`eth_getBlockReceipts` at ~0.58 s at both ends. The most likely explanation is a transient on the
endpoint or the network path. It was not diagnosed and is not claimed to be understood; the container
logs from that window were discarded by a later recreate.

**Two sizing decisions worth understanding before changing anything:**

- **cpu total is deliberately 2.75, under 3.0.** Flux applies a 0.8× multiplier when
  `instances<4 AND cpu<3 AND ram<6000 AND hdd<150`. Crossing 3.0 costs roughly a third more for
  headroom the measurements say is unnecessary. A cpu or ram change later requires a new subscription
  but does **not** destroy the volume — so this is cheap to revise upward if the explorer feels slow.
- **hdd 100 GB is oversized on purpose.** Changing `hdd` is a *hard* redeploy that destroys the volume
  on every instance. At 8.2 GiB/year that is a decade of runway, and blocks only get heavier as EVM
  usage arrives. At $0.02/GB it is the cheapest insurance in the spec.

`scripts/validate-spec.py` checks the spec against FluxOS's documented limits offline — worth running
after any edit, because `verifyappupdatespecifications` is blind on enterprise apps and the dashboard
only reports a failure after the whole wizard is filled in.

### Connection pool — why `max_connections` is *not* overridden

Blockscout's default pools open **~100 Postgres connections and hold them idle**; measured during a
catchup, only **1–2 were ever `active`**. Postgres defaults to `max_connections=100`, so out of the
box Blockscout consumes the entire connection budget and everything else — `psql`, a monitoring
probe, the migration task — fails with *"sorry, too many clients already"*. This is a real failure,
reported independently from a local run, and it reproduces exactly.

The obvious fix is to raise `max_connections` on the server. That treats the symptom; the connections
are not being used. Capping the client pools is both more conservative and materially cheaper:

| | connections | Postgres RSS | indexing rate |
|---|---|---|---|
| defaults | 100 | 469 MiB | ~22 blocks/s |
| `POOL_SIZE=20`, `POOL_SIZE_API=10` | **31** | **~150 MiB** | ~21 blocks/s |

So the pools are capped in the image and `bsdb` runs with **no `commands` override at all** — 31
connections sits comfortably inside Postgres's default 100. The ~325 MiB saved is why the `bsdb`
allocation keeps a wide margin at 1500 MB.

### Which fetchers are enabled

Blockscout ships roughly two dozen fetchers enabled by default. Four are switched off, and the
distinction is deliberate — **only things that cannot succeed here, or are provably wasted**:

| Disabled | Why |
|---|---|
| internal transactions | derives from tracing; the sidecar has none |
| block rewards | same — retries forever against an endpoint that cannot answer |
| pending transactions | nothing here depends on a mempool view |
| **empty blocks sanitizer** | re-fetches "empty" blocks to confirm them. On a chain where *every* block is empty it re-queries the whole chain forever, batch 10 every 10s, against a single-instance production endpoint. Observed running continuously; disabling it left the rate unchanged at ~21 blocks/s |

**Deliberately left enabled:** the token, NFT/token-instance and coin/token balance fetchers. They are
idle today only because the chain has no activity, and they are precisely what must work the moment
it does. Disabling those would not be conservative — it would make the explorer quietly wrong later.

`TRACE_FIRST_BLOCK` is likewise not set: it only bounds internal-transaction indexing, which is off.

### Which frontend features are enabled

The Blockscout frontend ships a large catalogue of optional integrations — ads, the DappScout
marketplace, Merits/rewards, analytics, chain-specific widgets. It prints an enabled/disabled
checklist at container boot, which is the authoritative audit: run the image and read it.

An unconfigured image reports **6 of 50 enabled**. Ours reports **3**:

| | Enabled |
|---|---|
| unconfigured upstream | Advanced filter, **Banner ads**, **Text ads**, API documentation, **Gas tracker**, Web3 wallet integration |
| this image | Advanced filter, API documentation, Web3 wallet integration |

**Ads are on by default** — upstream's docs state "ads are enabled by default on all self-hosted
instances." Left alone, a Quip-branded explorer would serve third-party crypto advertising and load
an ad network's scripts into every visitor's browser. Both are set to `none`.

The **gas tracker** is off because `/api/v2/stats` returns null for every gas price on this chain;
the widget renders empty and reads as broken. The **marketplace (DappScout)** was already off, but is
pinned explicitly — it is off only by *default*, and this is a floating upstream image, so a base
bump could flip it on.

Kept on deliberately: **API documentation** (directly useful for the dev-onboarding half of QUI-905)
and **Web3 wallet integration**, which provides "add Quip Testnet to MetaMask" — arguably the single
most useful button on a testnet explorer.

**Merits/rewards, Mixpanel, GrowthBook and Google Analytics are not set at all.** They activate only
when given an API host or token, which we never supply, so unlike a boolean default they cannot
switch on via an image bump. Adding inert variables to "disable" them would be config that looks
load-bearing and is not.

Re-run the audit after any base-image bump: `docker run --rm <ui-image>` and read the checklist.

### Backend HTTP surface, and GraphQL

What the public origin actually exposes, measured through the proxy with the real frontend behind it:

| Path | Reachable | Note |
|---|---|---|
| `/api/v2/*` | yes | required by the frontend |
| `/api?module=…` | yes | Etherscan-compatible, read-only — the `proxy` module is absent, so there is **no** `eth_sendRawTransaction` route and no transaction-submission surface |
| `/api-docs`, `/sitemap.xml`, `/socket` | yes | intended |
| `/metrics` | **no (404)** | contained by the single-origin routing — it does not match the backend regex, so it lands on the frontend. The backend does serve it on its own port, which Flux never publishes |
| `/admin`, account endpoints | no (404) | not enabled |
| CSV export | no (422) | reCAPTCHA-gated |
| **`/api/v1/graphql`, `/graphiql`** | **no (404)** | blocked at the proxy — see below |

**GraphQL is blocked in nginx, not in the app, and that distinction matters.** Blockscout 9.0.2
exposes a fully introspectable GraphQL endpoint plus the interactive `/graphiql` playground, with no
query-complexity bound — an open-ended cost surface on a public origin backed by a 0.75-cpu Postgres,
with no consumer in this stack.

The obvious control, `API_GRAPHQL_ENABLED=false`, **does not work on 9.0.2**. The variable exists in
upstream `master` but is not wired up in this release (blockscout/blockscout#11845 is the request to
add exactly it). This was caught by testing rather than trusting the name: with the variable baked
false, schema introspection still returned a full `RootQueryType`.

So enforcement lives in `nginx-explorer.conf.template` as two `^~` location blocks returning 404,
which also cover sub-paths. Verified: introspection through the proxy returns nginx's 404 while
`/api/v2`, `/api?module=`, `/api-docs`, `/sitemap.xml` and `/` all still serve. The backend continues
to answer GraphQL on its own port — that port is simply never published by Flux.

`API_GRAPHQL_ENABLED=false` is still set in the image as forward-defence, so that a future base bump
to a release which honours it gets app-layer enforcement too rather than depending solely on a proxy
rule surviving an edit.

**Re-enabling GraphQL means both** removing the nginx block **and** setting
`API_GRAPHQL_MAX_COMPLEXITY`. Turning it back on without a complexity bound restores the original
open-ended surface.

---

## 4. Cost

```
cpu   2.75 × 0.15 × 10  =  4.125
ram   4500 × 0.05/100   =  2.250
hdd   103 × 0.02        =  2.060
staticip                =  2.000
                           ------
raw                        10.435   →  ceil(10.435/3) = 4  per instance
× 1 instance × 0.8 (discount applies)
                        ≈  $3.20 / month
```

For comparison, `evm-rpc.testnet` costs a measured **$5.11/month** at 4 cpu / 8000 MB / 100 GB.

The **dashboard calculator is authoritative** — confirm there before subscribing. Flux subscriptions
are prepaid and non-refundable. Term discounts: 3 mo −3%, 6 mo −6%, 1 yr −12%.

`staticip: true` is kept even though FDM routes by CNAME rather than by A record, because it matches
every other Quip Flux app and changing it later needs a new subscription. Dropping it would save
about $0.53/month; not worth the deviation on an unrehearsed path.

---

## 5. Cert renewal — AC #5

**There is nothing to run and nothing to maintain.** FDM (Flux's managed load balancer) terminates
TLS and owns both issuance and renewal, on a ~90-day Let's Encrypt cycle.

This deployment therefore involves **no dnsimple-certifier, no `flux-dns-controller` registry entry,
no capability token and no Tarsnap cert seeding** — the entire bring-up ceremony that `evm-rpc`,
the bootnodes, `status` and `check` each carry. It is the single biggest operational simplification
of the FDM path and the reason AC #5 holds without a local renewal loop.

The trade is stated plainly in §7.

---

## 6. Deploy runbook

Ordering matters in two places; both are called out.

1. **Build and push the images.**
   ```sh
   PUSH=1 scripts/build-images.sh
   ```
   Builds amd64-only with `--provenance=false --sbom=false`, so each tag is a single-platform
   manifest and the printed digest *is* the image digest (no manifest-list child trap). The script
   asserts the baked env landed and fails if an image was built without `BAKE_PROD_ENV=1` — a
   silently neutral image starts cleanly and then indexes the wrong chain from block 0.

2. **Fill in the spec.** Replace the three `<REPLACE-*>` repotags with the pushed digests, the
   Postgres password (same value in `bsdb`'s `POSTGRES_PASSWORD` and `bsapi`'s `DATABASE_URL`), a
   freshly generated `SECRET_KEY_BASE` (`openssl rand -hex 64` — do **not** reuse the rehearsal value
   or the dev literal from !65), and a GitLab deploy token with `read_registry`.
   Then re-run `scripts/validate-spec.py`.

3. **⚠ Create the DNS record FIRST.** At DNSimple, `explorer.testnet.quip.network` CNAME →
   `quipexplorer.app.runonflux.io`. Confirm it resolves to `fdm-lb-*.runonflux.io` before going near
   the dashboard. This is a hand-created CNAME, *not* a `flux-dns-controller` tenant — the controller
   manages A records for direct-IP apps and is not involved here.

4. **Deploy via the cloud.runonflux.com dashboard**, not the API. Export the resulting spec — the
   export is canonical, the file in this repo is only a wizard starting point.

5. **Apply the Custom Domain** on the `bsproxy` port (App Settings → General → Custom Domain).
   Expect FDM's placeholder `CN=runonflux.io` cert for ~7 minutes and the real Let's Encrypt cert at
   ~8.5 minutes. Applying this *before* DNS resolves pushes FDM's ACME into backoff, which is why
   step 3 comes first.

6. **Verify** (§8), then update this document with the observed numbers.

Expect the first boot to look unhealthy for a while: `bsapi` retries its migration until `bsdb` is
accepting connections (Flux has no cross-component ordering primitive, so the entrypoint retries the
real migration rather than probing a port), and the initial backfill takes roughly 80 minutes before
the explorer shows full history. Neither is a fault.

---

## 7. End-to-end proof

Block indexing was verified by hash comparison, but the transaction, address and log paths could not
be — this chain's EVM had **never had a transaction**. `eth_getLogs` across all ~109k blocks of EVM
history returned zero logs, and every sampled block had `gasUsed: 0x0`.

So one was created. `scripts/send-test-transaction.mjs` funds a throwaway key from the faucet and
sends a single self-transfer:

```
tx      0x668389bc1dea63f714b798ab7a1fd5bb4685ef1c33e1fd8a4b04c176d5d3b693
block   1,095,350          status success, gasUsed 1,994,981
```

That is the **first EVM transaction in the chain's history** (2026-08-11).

The one Quip-specific step is funding. An Ethereum address is not itself an account on this chain:
the runtime uses `pallet_revive::AccountId32Mapper`, whose fallback derivation for an unmapped H160
is the 20 address bytes followed by twelve `0xEE` bytes. The faucet must be given *that* 32-byte
value — `POST /request {"dest": "0x<64 hex>", "amount": <plancks>}`. Sending to the H160 itself goes
nowhere. Amounts are in plancks (12 native decimals); balances over `eth_*` are in wei (18), bridged
by `ReviveNativeToEthRatio = 1_000_000`.

The explorer indexed it correctly:

| Page | Result |
|---|---|
| `/tx/<hash>` | status `ok`, block 1095350, gas 1,994,981, value 0.01, correct from/to |
| `/address/<addr>` | balance `9997005019000000000` wei — the funded amount minus gas |
| `/address/<addr>/transactions` | 1 transaction listed |

One caveat: `/api/v2/stats` still reports `total_transactions: 0` immediately afterwards. Those are
cached aggregate counters that Blockscout recomputes on a schedule; the per-transaction and
per-address pages are correct. Do not read the homepage tiles as a liveness check.

## 8. Known risks and accepted trade-offs

- **Raw-Docker FDM auto-TLS is documented but unrehearsed by us.** We have proven it on Orbit apps
  (`portal.testnet`, `asset-tracker`), never on a raw-Docker multi-component app. If issuance fails,
  the fallback is the in-container nginx + dnsimple-certifier pattern on a ported URL — same app,
  different proxy component, plus the Tarsnap-seed-before-DNS ceremony.
- **The origin port serves cleartext on the public instance IP.** `http://<instanceIP>:20050` is
  reachable directly. Accepted with the FDM choice; this is a read-only explorer. Note that FDM
  auto-registers `<appname>.app.runonflux.io` for every app, so the explorer is reachable by that
  name too.
- **Explorer availability is bounded by `evm-rpc`'s.** That app is a single instance with ~1 month of
  disk runway at the current ~1.87 GB/day GRANDPA AUX leak (QUI-954/955) before a wipe-and-resync.
  During such a window the explorer stalls at its last indexed block and resumes afterwards — no data
  loss, but this is not independent uptime.
- **Adding or removing a component later wipes every volume.** Stated rather than designed around:
  Blockscout's Postgres is 100% derived state, the recovery is a re-backfill from `FIRST_BLOCK`, and
  nothing in it is authoritative. It is deliberately **not** backed up.
- **Live-update tiles will reconnect periodically.** FDM closes idle WebSockets at ~25 s (measured)
  and Blockscout's Phoenix client heartbeats at 30 s. nginx is configured not to be the cause; the
  explorer is fully functional either way.
- **`X-Forwarded-For` is not a trustworthy client identity here.** FDM appends the real client as the
  right-most field after any client-supplied header, and nginx then appends FDM — so the real client
  is *second-to-last* and every earlier element is attacker-controlled. `X-Real-IP` is overwritten by
  our nginx precisely because FDM passes a client-supplied one through untouched. Nothing reads
  either today; anything that starts rate-limiting or logging by IP must take that position
  deliberately.
- **EIP-155 chain ID 20033 is not registered** on chainlist. Worth resolving before the explorer is
  advertised widely, since wallets use the registry to name a network. The related "20049 appears
  where 20033 belongs" documentation drift is already tracked as **QUI-974** (20049 is the *port*).
- **No pubsub and no filter API on the sidecar** — `eth_subscribe`, `eth_newFilter` and friends are
  absent, so every consumer must poll. This does not affect the explorer (Blockscout polls and keeps
  up), but it does affect dApp developers pointed at this RPC: ethers/viem configured with a
  **WebSocket** transport will never fire `provider.on("block", …)` or `watchContractEvent`, while the
  same code on an **HTTP** transport falls back to polling and works. Dev-facing docs should say "use
  the HTTP URL". Not tracked in Linear as of 2026-08-11; it is noted in the
  `bootnodes.quip.network` README as a "before advertising the endpoint publicly" caveat.
