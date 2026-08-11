# explorer.quip.network

Blockscout EVM block explorer for the Quip testnet — QUI-992 (the hosting half of QUI-905).

Serves `https://explorer.testnet.quip.network`, indexing the testnet's pallet-revive EVM via the
existing QUI-966 JSON-RPC sidecar at `evm-rpc.testnet.quip.network:20049`. No second adapter is stood
up; this repo contains only the packaging, the proxy and the Flux deployment.

## What is here

| Path | Purpose |
|---|---|
| `docker-compose.rehearsal.yml` | Measurement harness — Blockscout against the **live** endpoint, run locally |
| `scripts/rehearse.sh` | Driver for the above: `up` / `watch` / `status` / `sample` / `down` |
| `deploy/flux/` | Flux v8 app spec (a wizard starting point — the dashboard export is canonical) |
| `docs/` | Cost, resource shape and cert-renewal record |

## Chain facts this deployment is built on

Measured against the live endpoint, 2026-08-11:

- EIP-155 chain ID **20033** (`0x4e41`) — `ReviveChainId` on the testnet runtime, not the `1337`
  dev-chain-id build.
- EVM history starts at block **985,665**. Every block below that returns `null` from
  `eth_getBlockByNumber`, so `FIRST_BLOCK=985665` is mandatory — Blockscout's catchup fetcher
  otherwise defaults to block 0 and grinds on ~985k dead requests forever.
- Block time ~6.0 s (~14,300 blocks/day).
- The sidecar serves `eth_*` only: `trace_block` returns *Method not found* and
  `debug_traceBlockByNumber` returns `[]`. Hence `ETHEREUM_JSONRPC_VARIANT=anvil` and the internal /
  pending transaction fetchers disabled — that is the accurate configuration, not a workaround.
  Internal transactions and block rewards are genuinely unavailable from this endpoint.

## Rehearsal

```sh
scripts/rehearse.sh up       # generates .env.rehearsal, pulls, starts
scripts/rehearse.sh status   # one-line progress
scripts/rehearse.sh watch    # ticks until backfill completes, then exits
scripts/rehearse.sh down     # stops and REMOVES the volume
```

Output lands in `rehearsal/metrics.csv` (gitignored). It exists to answer four questions with numbers
rather than upstream's mainnet-sized guesses: backfill wall-clock, peak backend RSS, peak Postgres
RSS, and `pg_database_size` at head.

Backfill traffic is deliberately throttled (`INDEXER_CATCHUP_BLOCKS_CONCURRENCY=4`,
`INDEXER_CATCHUP_BLOCKS_BATCH_SIZE=10`, against upstream defaults of 10/10). `evm-rpc.testnet` is a
single Flux instance with no rate limit configured and no redundancy, and it is a live BD endpoint.

## Operational notes

Blockscout's Postgres is **100% derived state**. Nothing in it is authoritative and it is not backed
up; the recovery for any volume loss is a re-backfill from `FIRST_BLOCK`. This is what makes the Flux
"changing `hdd` or adding a component destroys the volume" constraint tolerable.

## License

AGPL-3.0-or-later.
