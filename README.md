# explorer.quip.network

Blockscout EVM block explorer for the Quip testnet — QUI-992 (the hosting half of QUI-905).

Serves `https://explorer.aglais.quip.network`, indexing the testnet's pallet-revive EVM via the
existing QUI-966 JSON-RPC sidecar at `evm-rpc.aglais.quip.network:20049`. No second adapter is stood
up; this repo contains only the packaging, the proxy and the Flux deployment.

## What is here

| Path | Purpose |
|---|---|
| `Dockerfile.{api,ui,proxy}` | The three deployed images — Blockscout built from source, plus baked config and a trust-store check |
| `trust-store/assert-fixed-bundle.sh` | Fails a build whose CA bundle still trusts the forged eMudhra roots (QUI-1930) |
| `nginx-explorer.conf.template` | Single-origin proxy: UI at `/`, backend at `/api`, `/socket`, … |
| `deploy/flux/` | Flux v8 app spec (a wizard starting point — the dashboard export is canonical) |
| `scripts/build-images.sh` | Build/push, amd64-only, asserts the bake landed |
| `scripts/validate-spec.py` | Offline Flux constraint checker for the app spec |
| `docker-compose.preview.yml` + `scripts/preview.sh` | Run the **deployed images** locally for sign-off |
| `docker-compose.rehearsal.yml` + `scripts/rehearse.sh` | Measurement harness against the live endpoint |
| `scripts/send-test-transaction.mjs` | End-to-end proof: puts a real transaction on the testnet |

## Chain facts this deployment is built on

Measured against the live endpoint, 2026-08-11:

- EIP-155 chain ID **20033** (`0x4e41`) — `ReviveChainId` on the testnet runtime, not the `1337`
  dev-chain-id build.
- EVM history starts at block **0**, so `FIRST_BLOCK=0`. Aglais was relaunched with
  pallet-revive already in the genesis runtime, so there is no pre-EVM prefix to skip.
  Measured 2026-09-02 against the live endpoint (with `eth_syncing:false` asserted first,
  since a syncing node returns `null` at low heights and yields a wrong HIGH answer):
  `eth_getBlockByNumber(0)` → 0, `(1)` → 1.
  On the OLD chain this was **985,665** — revive arrived there by runtime upgrade partway
  through, so every block below that returned `null` and the catchup fetcher would grind on
  ~985k dead requests. Carrying that value onto aglais would index nothing for ~340 days.
- Block time ~6.0 s (~14,300 blocks/day).
- The sidecar serves `eth_*` only. `trace_block` returns *Method not found* and
  `debug_traceBlockByNumber` returns `[]`, so `ETHEREUM_JSONRPC_VARIANT=anvil` with the internal and
  block-reward fetchers disabled is the accurate configuration, not a workaround — internal
  transactions and block rewards are genuinely unavailable from this endpoint.
- **No pubsub.** The WebSocket upgrades and carries JSON-RPC, but `eth_subscribe` returns *Method not
  found*. Realtime indexing therefore works by polling `eth_blockNumber`, and
  `ETHEREUM_JSONRPC_WS_URL` is deliberately not set. Consequence for developers pointed at this RPC:
  ethers/viem on a **WebSocket** transport will never fire `provider.on("block")`; on **HTTP** they
  poll and work.

## Resource shape and cost

Measured, not guessed. Upstream Blockscout publishes 16-core / 128 GB sizing that describes Ethereum
mainnet and says nothing about a chain with ~109k mostly-empty EVM blocks.

| Component | Peak RSS | Allocated cpu / ram / hdd |
|---|---|---|
| `bsapi` | 472 MiB | 1.25 / 2000 MB / 1 GB |
| `bsdb` | 469 MiB | 0.75 / 1500 MB / **100 GB** |
| `bsui` | 186 MiB | 0.5 / 700 MB / 1 GB |
| `bsproxy` | 10 MiB | 0.25 / 300 MB / 1 GB |
| **Total** | | **2.75 cpu / 4500 MB / 103 GB → $3.86/month** (enterprise; $2.78 plain) |

Those two figures come from Flux's own oracle, `POST /apps/calculatefiatandfluxprice`, not from arithmetic:
the spec as written quotes `{"usd": 2.78}`, and `scripts/validate-spec.py` reproduces that to the cent on
three arms (staticip off → 2.26, `hdd` 150 → 3.44). Note FluxOS ceilings the per-instance price to **cents**
(`appUtilities.js:125`), not to whole dollars — an integer ceiling overstates this spec by ~$0.40 and is where
an earlier `$3.20 / $4.00` came from. Flux's *documentation* is also stale here: it prices enterprise at $0.80
and static IP at $0.40, while the live rate table charges 4 and 2 pre-divisor. Enterprise really costs
**+$1.08/month**; paying in FLUX takes a further 5% off.

Full backfill: **108,790 blocks in 117 min**, zero gaps, `finished_indexing: true`. Database at head
**136 MiB** = 1,313 bytes/block ≈ **6.4 GiB/year**. Rate is not constant — it held ~22 blocks/s for
the first ~4,000 s then stepped down to ~7–8.5, so **budget ~2 hours for a backfill**.

Two sizing decisions that are load-bearing:

- **cpu total is deliberately under 3.0.** Flux applies a 0.8× multiplier when `instances<4 AND cpu<3
  AND ram<6000 AND hdd<150`. A cpu or ram change later needs a new subscription but does *not*
  destroy the volume — only an `hdd` change does — so this is cheap to revise upward.
- **`hdd` 100 GB on day one.** Changing it is a hard redeploy that destroys the volume on every
  instance. At 6.4 GiB/year that is over a decade of runway, and it costs $0.02/GB.

**Image size does not count against a component's `hdd`.** Worth stating because `bsui` is an 878 MB
image against `hdd: 1`, which looks alarming and is fine. `hdd` is `fallocate`'d into a separate volume
file mounted at `containerData` (`advancedWorkflows.js:517`); image layers live on the container's root
filesystem, which gets an independent quota of `hddFileSystemMinimum` = 10 GB
(`dockerService.js:1000-1012`), and only on xfs nodes with `pquota` — elsewhere it is unquotad.

Run `scripts/validate-spec.py` after any spec edit — Flux's own `verifyappupdatespecifications` is
blind on enterprise apps, and the dashboard only reports failures after the whole wizard is filled in.

## What is enabled, and what is not

Blockscout ships a large default-on surface. The rule applied here: **disable what cannot succeed or
is provably wasted; keep what is merely idle.**

**Contract verification goes through Blockscout's hosted verifier,** by decision (Keith, 2026-11-25).
`MICROSERVICE_SC_VERIFIER_ENABLED` defaults to true, with `https://eth-bytecode-db.services.blockscout.com`
as its URL, and we leave both alone:

- **What goes out:** when someone verifies a contract, the explorer sends the submitted source and
  settings there, and the verify form fetches its compiler list from there. This has been so since the
  9.0.2 deploy.
- **What does not:** viewing a contract sends nothing. The on-demand lookup of unverified contracts
  runs only with `MICROSERVICE_SC_VERIFIER_TYPE=eth_bytecode_db`, and the type defaults to
  `sc_verifier`. Checked with socket inspection on 2026-11-25.
- **Why it isn't turned off:** off, Blockscout verifies locally by running `node priv/compile_solc.js`,
  which needs node and the `solc` npm package. Upstream's image ships neither, so local verification
  fails with `:enoent`. Adding node and the wrapper from upstream's own lockfile made it work in the
  rehearsal (`MessageStore` verified, nothing sent to Blockscout). That stays available if the decision
  changes.

**Indexer fetchers off:** internal transactions and block rewards (both derive from tracing the
sidecar does not have, so they retry forever); pending transactions; and the **empty-blocks
sanitizer** — it re-fetches "empty" blocks to confirm them, and on a chain where every block is empty
it re-queries the whole chain forever against a single-instance endpoint.

**Left on deliberately:** the token, NFT/token-instance and coin/token balance fetchers. They are idle
only because the chain has no activity yet and are exactly what must work once it does.

**Frontend:** an unconfigured image reports 6 of 50 features enabled; this one reports 3 — Advanced
filter, API documentation, Web3 wallet integration. **Ads are on by default upstream** ("ads are
enabled by default on all self-hosted instances") and are switched off, along with the gas tracker
(every gas price is null on this chain) and the marketplace/DappScout. Merits, Mixpanel, GrowthBook
and Google Analytics need an API host or token that is never supplied, so they cannot switch on via
an image bump. **Re-run the audit after any base bump:** `docker run --rm <ui-image>` and read the
boot checklist.

**Connection pool:** Blockscout's defaults open ~100 Postgres connections and hold them idle while
only 1–2 are ever active — which exhausts Postgres's default `max_connections=100` and produces
*"sorry, too many clients already"* for everything else. Capped at `POOL_SIZE=20` /
`POOL_SIZE_API=10`, taking connections to 31 and Postgres RSS from 469 MiB to ~150 MiB with no change
in indexing rate. `bsdb` therefore needs **no `max_connections` override**.

**GraphQL is blocked at the proxy.** Enforcement is two `^~` location blocks in nginx returning 404.
`API_GRAPHQL_ENABLED=false` did nothing on 9.0.2, where blockscout/blockscout#11845 had not landed and
schema introspection still succeeded with it baked false. 12.1.0 reads it, so the app refuses GraphQL
too. Re-enabling means removing the nginx blocks **and** setting `API_GRAPHQL_MAX_COMPLEXITY`, or the
original unbounded surface comes back.

`/metrics` is not publicly reachable: it does not match the backend route, so it lands on the
frontend as a 404. The Etherscan-compatible `proxy` module is absent, so there is no
`eth_sendRawTransaction` route through the explorer.

## Blockscout is built from source (QUI-2535)

Blockscout stopped publishing public images after backend **9.0.2** and frontend **v2.3.5**. ghcr's
`blockscout/blockscout` and `blockscout/frontend` end there (`latest` included), and every newer tag
answers 404. The maintainers say this is on purpose (blockscout#13226, #14381): they point people at
their hosted Autoscout and Explorer-as-a-Service, and their builds go only to `-private` registries.

So `scripts/build-images.sh` first builds both bases from upstream's own Dockerfiles at commits it
pins, then our three images `FROM` them:

| Base | Upstream | Pinned commit | Built locally as |
|---|---|---|---|
| backend | blockscout/blockscout v12.1.0 | `066e39b5` | `local/blockscout-backend:12.1.0-066e39b5` (3m40s on 22 cores) |
| frontend | blockscout/frontend v2.13.0 | `d3cfa7ab` | `local/blockscout-frontend:v2.13.0-d3cfa7ab` (6 min) |

Only our images are pushed, and they carry every base layer. A base already built at the pinned
commit is reused; `REBUILD_BASES=1` rebuilds it. Bumping Blockscout means changing the pins in
`build-images.sh` (and the default `BLOCKSCOUT_*IMAGE` in the Dockerfiles), then rehearsing.

**What changed from 9.0.2 that our settings had to follow:**

- **`ECTO_SSL_MODE=disable` replaces `ECTO_USE_SSL=false`.** 12.1.0 does not read `ECTO_USE_SSL`
  at all, and it ignores the `ssl=false` in our `DATABASE_URL`; it only knows `sslmode`. Its default
  is `require`, so without this every connection to `bsdb` fails at startup.
- **`DISABLE_MARKET` replaces `DISABLE_EXCHANGE_RATES`.** The old name still works as a fallback.
- **An existing 9.0.2 database cannot be upgraded straight to 12.x:** v11.0.0 "must be installed on
  top of v10.1". We re-index from scratch instead; see "Moving to 12.1.0" below.
- **The frontend refuses to start on an empty value it does not accept** (since v2.10.0). Production
  bakes real values. The neutral rehearsal image leaves some empty, so the rehearsal compose sets them.

**Trust store.** Each image upgrades Alpine's CA bundle and fails the build unless it is the fixed
one. The API also checks the CA files Blockscout's Elixir libraries carry (castore, certifi). Checked
inside the images on 2026-11-25 against the forged-root test hosts `dv-g3b-emudhra` and
`dv-g3b-aaa-emudhra` (`.we-have-a-problem.com`), with observe.quip.network as the control:

| Client | Trusts | Forged hosts | Control |
|---|---|---|---|
| API: Mint, which the RPC transport uses (castore 1.0.22) | castore's file | refused | reached |
| API: hackney (certifi 2.18.0) | certifi's file | refused | reached |
| API: `:httpc` | the OS bundle | refused | reached |
| UI: node 24.21.0, **upstream's image as built** | node's own roots | **G3B accepted** | reached |
| UI: node 24.21.0, **ours** (`NODE_OPTIONS=--use-openssl-ca` + fixed bundle) | the OS bundle | refused | reached |

certifi's compiled root list holds no forged root either. The UI row is the reason the layer exists:
upstream's v2.13.0 image trusts the forged chain through node's bundled roots.

### Moving to 12.1.0: a fresh re-index

An explorer's database is an index of the chain, so the move re-indexes from block 0 instead of
upgrading the 9.0.2 database in place (which would have to pass through v10.1 first). One spec
update carries it, together with QUI-2534's sidecar image:

| Component | Change |
|---|---|
| `bsapi`, `bsui`, `bsproxy` | repotags to the new from-source images |
| `bsbak` | repotag to the guarded sidecar (QUI-2534) |
| `bsdb`, `bsbak` | `S3_PREFIX=explorer-postgres/aglais-c7145a3f-bs12`: a new, empty prefix naming the current chain, so `bsdb` finds no dump and starts empty |
| `bsdb` | `PGDATA=/var/lib/postgresql/data/pgdata-bs12`: a new data directory, so a kept volume's 9.0.2 data is ignored |

Write down the current repotags, `S3_PREFIX` and `PGDATA` before changing them. All three together
are the **rollback**, and the 9.0.2 database and its dumps are left untouched for it.

**What the explorer shows meanwhile.** Blockscout indexes from the chain head **down** to block 0, so
the newest blocks and transactions appear within minutes and older history fills in behind them.
Until that finishes, history is partial and `/api/v2/stats` totals run low: they come from
Postgres's planner estimate, which a fresh table updates only after autovacuum analyzes it.
The "indexed" ratio in `/api/v2/main-page/indexing-status` is built on that same count, cached for
`CACHE_BLOCK_COUNT_PERIOD` (2 h by default). So it can trail the real state by up to two hours after
the backfill ends: the data is complete and served while the figure still reads, say, 0.73.

Rehearsed on 2026-11-25, with our 12.1.0 images on an empty database at production's pacing (4 × 10
blocks in flight):

- **The backfill:** all 168,683 blocks in 10,850 s (3 h 01 m, about 15.5 blocks/s), against the live
  EVM RPC, into a 170 MiB database.
- **Checked against production's 9.0.2:** five sample block hashes (1, 53,340, 100,000, 150,000 and
  168,000) and `MessageStore`'s creating transaction matched, and so did the transaction total (386).

**The one thing the chain cannot give back** is verified source code. On 2026-11-25 there was one
verified contract, `MessageStore` at `0x9785D9d0953611c2Ab66Bbb97b470b45d90fc721`: Solidity
v0.8.24+commit.e11b9ed9, optimization on with 200 runs, default EVM version, MIT. It is re-submitted
after the move through `/api/v2/smart-contracts/<address>/verification/via/flattened-code`.

## Deploying

Ordering matters in two places; both are called out.

0. **The GitLab project must exist.** The container registry lives under it, so nothing can be pushed
   until it does, and every step below depends on that push.
1. `PUSH=1 scripts/build-images.sh` — amd64-only, `--provenance=false --sbom=false` so each tag is a
   single-platform manifest whose printed digest *is* the image digest. It fails if an image was
   built without `BAKE_PROD_ENV=1`; a silently neutral image starts cleanly and indexes the wrong
   chain from block 0.
2. Fill the spec: the three digests, a fresh `SECRET_KEY_BASE` (`openssl rand -hex 64`), and the
   Postgres password — which goes in **two** places, `bsdb`'s env and `bsapi`'s `DATABASE_URL`.
   Re-run `scripts/validate-spec.py`. `repoauth` stays **empty**: this project is public, so its
   registry is anonymously pullable, and a placeholder credential would be sent verbatim and answered
   with a 401 rather than falling back to anonymous.
3. **⚠ Create the DNS record FIRST.** DNSimple CNAME `explorer.aglais.quip.network` →
   `quipexplorer.app.runonflux.io`; confirm it resolves to `fdm-lb-*.runonflux.io` before touching
   the dashboard. This is a hand-created CNAME, *not* a `flux-dns-controller` tenant.
4. Deploy via the cloud.runonflux.com dashboard, not the API. Export the resulting spec — the export
   is canonical.
5. Apply the Custom Domain on the `bsproxy` port. Expect FDM's placeholder `CN=runonflux.io` cert for
   ~7 min and the real Let's Encrypt cert at ~8.5 min. Applying before DNS resolves pushes FDM's ACME
   into backoff, which is why step 3 comes first.

### Two Flux-specific landmines, both found by the dashboard rejecting a valid-looking spec

**`repotag` must carry a `:TAG`, even when digest-pinned.** FluxOS's `ImageVerifier.imagePattern`
parses only `[HOST/][NAMESPACE/]REPOSITORY[:TAG]` and has no `@sha256:` branch at all, so a bare
`repo@sha256:…` parses as `namespace=repo, repository='', tag=undefined` and is rejected with
*"Authentication failed: … not available or doesn't exist"* — which reads as a credentials problem and
is not one. Use `repo:TAG@sha256:DIGEST`: the regex stops at the `@` and ignores the digest tail, while
Docker still honours the digest on pull. The dashboard reports only the **first** offending component,
so fix all of them at once. `scripts/validate-spec.py` now enforces this.

**Blockscout cannot parse an underscore in the DB hostname.** Blockscout extracts DB parameters
from `DATABASE_URL` with a regex (`explorer/repo/config_helper.ex`, line 63 in 9.0.2 and line 130 in
12.1.0, unchanged) whose hostname class is letters, digits, hyphen and dot. Flux's inter-component DNS name is *always* `flux<component>_<appname>`, so the
URL never matches, `Regex.named_captures` returns `nil`, and `Keyword.new(nil)` raises
`(Protocol.UndefinedError) protocol Enumerable not implemented for nil` during repo init — before a
socket is opened. It therefore looks exactly like "the database is not up yet", and no amount of
retrying helps. **No compose rehearsal can surface this**, because a compose service name (`bsdb`) has
no underscore. `entrypoint-api.sh` decomposes such a URL into `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/
`PGDATABASE`, which Postgrex reads directly with no such restriction; `PGHOST` keeps the *name*, so it
re-resolves on reconnect and survives `bsdb` changing IP.

**The app must be enterprise/encrypted.** A non-enterprise app's `compose` is readable from Flux's
public API, and `environmentParameters` is part of it — deploying otherwise publishes
`SECRET_KEY_BASE` and the Postgres password. This is about the app's own secrets and would be
required even with a private registry. Enterprise adds $1.08/month. It also **disables geolocation
targeting**, which is the documented escape from a sick host — the Priority Nodes tab replaces it. Decide
before subscribing;
switching later means a new subscription.

Expect the first boot to look unhealthy for a while: `bsapi` retries its migration until `bsdb`
accepts connections (Flux has no cross-component ordering primitive, so the entrypoint retries the
real migration rather than probing a port), and the initial backfill takes ~2 hours. Neither is a
fault. Homepage stat tiles lag further still — they are cached aggregates recomputed on a schedule,
so do not read them as a liveness check.

## Verifying

`scripts/preview.sh up` runs the **deployed images** locally on one origin, and
`scripts/preview.sh check` asserts the decisions above against the running stack — GraphQL and
`/metrics` blocked, site/API/docs/sitemap serving, the frontend checklist showing exactly three
features, the empty-blocks sanitizer silent.

`scripts/send-test-transaction.mjs` proves the transaction path end to end. The non-obvious part is
funding: **an Ethereum address is not itself an account on this chain.** The runtime uses
`pallet_revive::AccountId32Mapper`, whose fallback derivation for an unmapped H160 is the 20 address
bytes followed by twelve `0xEE` bytes — and it is *that* 32-byte value the faucet must be given
(`POST /request {"dest": "0x<64 hex>", "amount": <plancks>}`). Sending to the H160 goes nowhere.
Amounts are plancks (12 decimals); `eth_*` balances are wei (18), bridged by
`ReviveNativeToEthRatio = 1_000_000`.

## Operational notes

Blockscout's Postgres is **100% derived state**. Nothing in it is authoritative, and the recovery
for any volume loss is a re-backfill from `FIRST_BLOCK`. That is what makes Flux's "changing `hdd`
or adding a component destroys the volume" constraint tolerable.

A relocation does not have to cost that re-backfill. `bsdb` runs the db image of
[flux-postgres-backup-restore](https://gitlab.com/quip.network/flux-postgres-backup-restore), and the
`bsbak` component dumps it to Storj every hour. After a relocation, `bsdb` restores the newest dump
and Blockscout catches up from there. A missing or bad dump only means the re-backfill. `bsbak` pings
the OneUptime monitor `explorer: postgres backup` after every stored dump.

Cert renewal is **FDM's**, on a ~90-day Let's Encrypt cycle. There is no dnsimple-certifier, no
`flux-dns-controller` registry entry, no capability token and no Tarsnap cert seeding — the entire
bring-up ceremony the bootnodes, `evm-rpc`, `status` and `check` each carry. Nothing to run.

Known limits:
the origin port serves cleartext behind FDM, which terminates TLS and re-originates in the clear; the
explorer's availability is bounded by the upstream RPC endpoint, which is currently a single
instance; and EIP-155 chain ID 20033 is not registered on chainlist.

## License

AGPL-3.0-or-later.
