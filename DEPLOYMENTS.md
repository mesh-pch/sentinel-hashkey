# Deployments

## HashKey Chain **testnet** (chain id 133) — live demo stack

Explorer: https://testnet-explorer.hsk.xyz (official; address/tx pages use `/address/<addr>` and `/tx/<hash>`)
Deployed 2026-10-27 from `0x1f47f871Cc8a9Eb90f38DfdcC1689C374500Bf70` (owner/deployer); agent key `0xE7bD08FabDC2147C60e52e70FeB898230B97D069` (trade-only), deploy block 34977817.

| Contract | Address |
|---|---|
| **AgentVault** (demo vault, 100k mUSDT deposited) | [`0xACdB76B454E9D845f650c0Ad30195E525856e01c`](https://testnet-explorer.hsk.xyz/address/0xACdB76B454E9D845f650c0Ad30195E525856e01c) |
| StrategyRegistry | [`0xf25bc69cb149258A1d95519E45020A68930ccd88`](https://testnet-explorer.hsk.xyz/address/0xf25bc69cb149258A1d95519E45020A68930ccd88) |
| VaultFactory | [`0x4Eca5D66529Dfc2cEB23f650Cc8f0fe0d2ae15a8`](https://testnet-explorer.hsk.xyz/address/0x4Eca5D66529Dfc2cEB23f650Cc8f0fe0d2ae15a8) |
| PushOracle (testnet stand-in) | [`0x8383854D98D0339D82F69d7bF9Baa69dbC559bcD`](https://testnet-explorer.hsk.xyz/address/0x8383854D98D0339D82F69d7bF9Baa69dbC559bcD) |
| SimVenue (testnet stand-in) | [`0x0adf752Aa5a20C0a85aE615169481B100168c568`](https://testnet-explorer.hsk.xyz/address/0x0adf752Aa5a20C0a85aE615169481B100168c568) |
| mUSDT / mWBTC / mWETH (mock tokens) | [`0x0A10…4287`](https://testnet-explorer.hsk.xyz/address/0x0A10069225527aF05db49b21e04B535D9aB84287) / [`0x6BFd…B14E`](https://testnet-explorer.hsk.xyz/address/0x6BFd2655fE5eCA056E5024C018A4A4C7cA15B14E) / [`0x3eAB…30FC`](https://testnet-explorer.hsk.xyz/address/0x3eABb7B81FD69feEF6b322A424180B6FB71530FC) |

Machine-readable: [`deployments/133.json`](deployments/133.json).

### Live agent run on testnet (30 hash-chained log entries: 4 trades + 26 holds)

`python -m sentinel verify` → **PASS** (log recomputes from events, 29/29 distinct decisions published and untampered, trades match declared orders). Published decision records: [`docs/testnet/decisions/`](docs/testnet/decisions), report: [`docs/testnet/report.html`](docs/testnet/report.html), JSON: [`docs/testnet/verification.json`](docs/testnet/verification.json). Replay it yourself:

```bash
RPC_URL=https://testnet.hsk.xyz DEPLOYMENT=deployments/133.json PYTHONPATH=agent \
  python3 -m sentinel verify --run-dir docs/testnet
```

Trade transactions:
- [`0x3366a523…97204ed`](https://testnet-explorer.hsk.xyz/tx/0x3366a523e674369ed35fe7d7e943ae2519c5d3bd62602ca4967556c8097204ed)
- [`0x8b64bd8c…e4c65`](https://testnet-explorer.hsk.xyz/tx/0x8b64bd8cb9d9d198a7e65fc161b2ad66e0b319610121a45e3b9a92e630be4c65)
- [`0xe805d57a…69af1`](https://testnet-explorer.hsk.xyz/tx/0xe805d57a52dad3e72d56dab0eaaa909bf94abb5b1f82f2ebcb44c63b06269af1)
- [`0x964f4f32…e2515`](https://testnet-explorer.hsk.xyz/tx/0x964f4f32fbfe2292c23bc649c73d0e70bb0df6d73819a6823cd9a9dd34ee2515)

The red-team probe was also run against this vault: 90 %-of-NAV trade, `minOut = 0`, unlisted venue and agent `withdraw()` were all rejected by the contract.

## HashKey Chain **mainnet** (chain id 177)

_Pending._ `scripts/deploy_mainnet.sh` deploys StrategyRegistry + VaultFactory + registers the strategy (≈ 4.24 M gas ≈ 2.12 HSK at 500 gwei).
