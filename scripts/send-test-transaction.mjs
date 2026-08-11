// SPDX-License-Identifier: AGPL-3.0-or-later
//
// End-to-end proof that the explorer works: puts one real transaction on the
// Quip testnet EVM and prints the explorer URLs for it.
//
// Requires ethers, which is not a dependency of this repo:
//   mkdir -p /tmp/ethtest && cd /tmp/ethtest && npm init -y && npm i ethers
//   node <path-to-this-file>/send-test-transaction.mjs
//
// ⚠ This WRITES to the live testnet. The transaction is permanent. It is a
// testnet and the faucet mints via sudo, so nothing of value is spent, but do
// not run it casually against anything else.
//
// First run: 2026-08-11, tx 0x668389bc1dea63f714b798ab7a1fd5bb4685ef1c33e1fd8a4b04c176d5d3b693
// in block 1,095,350 -- the first EVM transaction in this chain's history.
//
// Throwaway key, generated fresh each run and printed. Nothing of value is
// held by it; the faucet mints test funds via sudo.
//
// The one Quip-specific step is deriving the chain account for an Ethereum
// address. The runtime uses pallet_revive::AccountId32Mapper, whose fallback
// derivation for an unmapped H160 is the 20 address bytes followed by twelve
// 0xEE bytes. That 32-byte value is what the faucet must fund -- sending to
// the H160 itself would go nowhere.
import { ethers } from 'ethers'

const RPC = 'https://evm-rpc.testnet.quip.network:20049/'
const FAUCET = 'https://faucet.testnet.quip.network/request'
const CHAIN_ID = 20033n
// 12 native decimals -> 18 EVM decimals (ReviveNativeToEthRatio = 1_000_000)
const NATIVE_TO_ETH_RATIO = 1_000_000n
// 10 AGLS in plancks (12 decimals). Comfortably covers gas plus the
// existential deposit and any address-mapping deposit.
const FUND_PLANCKS = 10_000_000_000_000n

const log = (...a) => console.log(...a)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function accountIdFor (h160) {
  // 20 address bytes ++ [0xEE; 12]
  return ethers.concat([ethers.getBytes(h160), new Uint8Array(12).fill(0xee)])
}

const provider = new ethers.JsonRpcProvider(RPC, {
  chainId: Number(CHAIN_ID),
  name: 'quip-testnet'
})
const wallet = ethers.Wallet.createRandom().connect(provider)
const accountId = ethers.hexlify(accountIdFor(wallet.address))

log('')
log('  eth address   ', wallet.address)
log('  chain account ', accountId)
log('')

const net = await provider.getNetwork()
if (net.chainId !== CHAIN_ID) throw new Error(`wrong chain: ${net.chainId}`)
log('  connected, chainId', net.chainId.toString(), 'head', await provider.getBlockNumber())

log('  requesting faucet funds...')
const res = await fetch(FAUCET, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ dest: accountId, amount: Number(FUND_PLANCKS) })
})
const body = await res.text()
log(`  faucet HTTP ${res.status}: ${body.slice(0, 240)}`)
if (!res.ok) throw new Error('faucet refused')

log('  waiting for the balance to appear over eth_getBalance...')
let bal = 0n
for (let i = 0; i < 60; i++) {
  bal = await provider.getBalance(wallet.address)
  if (bal > 0n) break
  await sleep(3000)
}
if (bal === 0n) throw new Error('funds never arrived at the EVM address')
log(`  balance ${ethers.formatEther(bal)} AGLS (${bal} wei)`)

// Self-transfer: the smallest thing that is unambiguously a real transaction.
const value = ethers.parseEther('0.01')
const feeData = await provider.getFeeData()
log(`  gasPrice ${feeData.gasPrice}`)

const tx = await wallet.sendTransaction({
  to: wallet.address,
  value,
  gasLimit: 3_000_000n,
  gasPrice: feeData.gasPrice,
  chainId: CHAIN_ID
})
log('')
log('  SENT  ', tx.hash)
log('  waiting for inclusion...')
const rcpt = await tx.wait(1)
log('')
log('  MINED')
log('    block   ', rcpt.blockNumber)
log('    status  ', rcpt.status === 1 ? 'success' : 'FAILED')
log('    gasUsed ', rcpt.gasUsed.toString())
log('    from    ', rcpt.from)
log('    to      ', rcpt.to)
log('')
log('  explorer:')
log('    http://localhost:20050/tx/' + tx.hash)
log('    http://localhost:20050/address/' + wallet.address)
log('    http://localhost:20050/block/' + rcpt.blockNumber)
log('')
