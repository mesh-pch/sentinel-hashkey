# Sentinel — an AI trading agent that can trade, but can never run off with your money

> HashKey Chain Horizon Hackathon (Mumbai Edition) · **AI Agent Trading** track · built during the event window (Oct–Nov 2026)

**▶ Demo video (3:00, English voiceover + captions):** [docs/demo.mp4](docs/demo.mp4) · [release asset](https://github.com/mesh-pch/sentinel-hashkey/releases/download/v1.0-hackathon/demo.mp4)
**⛓ Live on HashKey Chain mainnet (177), source-verified on Blockscout:**
[`StrategyRegistry 0x0A10…4287`](https://hsk.blockscout.com/address/0x0A10069225527aF05dB49B21e04B535D9aB84287) ·
[`VaultFactory 0x6BFd…B14E`](https://hsk.blockscout.com/address/0x6BFd2655fE5eCA056E5024C018A4A4C7cA15B14E) — strategy #1 registered. Trading demo vault on testnet (133): [`0xACdB…e01c`](https://testnet-explorer.hsk.xyz/address/0xACdB76B454E9D845f650c0Ad30195E525856e01c). See [DEPLOYMENTS.md](DEPLOYMENTS.md).
**Verify in 60 s:** `forge test` (23 pass) · `cd agent && python -m pytest -q` (8 pass) · `python -m sentinel verify` (re-hashes every decision from public chain events).

Most "AI trading agent" demos hand a bot a private key and hope. **Sentinel inverts that**: the agent holds *no* withdrawal
rights, every trade is bounded by **limits enforced in Solidity**, and every decision — including the agent's reasoning —
is **hash-committed on-chain** so anyone can audit it after the fact.

| Problem with AI agents managing funds | Sentinel's answer (all on-chain, all tested) |
|---|---|
| Agent key compromised / model goes rogue | Agent can only call `executeTrade` / `recordHold`. `withdraw`, config, limits are `onlyOwner`. Worst case is bounded by the limits below. |
| One bad trade wipes the vault | Max trade size (% NAV), rolling-24h turnover cap, min interval between trades. |
| "Accept any price" / sandwiching | `minAmountOut` must be ≥ oracle-fair output − `maxSlippageBps`, else revert (`SlippageTooLoose`). Fills are measured from the vault's own balance deltas, so a lying venue cannot fake output or overspend. |
| Slow bleed | Drawdown circuit breaker vs high-water mark: vault halts itself (anyone may poke it); only the owner can resume. |
| Bad / stale prices | Oracle staleness bound; push-oracle per-update move bound. Trading stops when prices are stale; **owner withdrawal never depends on the oracle.** |
| "Trust me, the AI had good reasons" | Each tick the agent publishes a canonical-JSON decision record (inputs, signals, expert weights, orders, rationale). `keccak256(record)` goes on-chain with the trade/hold and is folded into a **hash-chained log** (`logHead`). `python -m sentinel verify` recomputes the chain from public events and re-hashes every record. Edit one word later → `FAIL`. |
| Bad strategy shipped to many vaults | `StrategyRegistry`: authors register a strategy (name, URI, `paramsHash` of the agent's parameters). Vaults check `isActive(id)` on **every** trade → author kill switch. The agent's params hash is committed there. |

## Architecture

```mermaid
flowchart LR
  subgraph Offchain["Off-chain agent (Python)"]
    M[Market data<br/>CoinGecko / fixture] --> B[Hedge ensemble<br/>trend · mean-rev · breakout · guard<br/>online multiplicative-weights learning]
    B --> V[Vol-targeted<br/>target weights]
    V --> L{{Optional LLM reviewer<br/>veto / scale DOWN only}}
    L --> D[Decision record<br/>canonical JSON]
  end
  D -- "keccak256 = decisionHash" --> AV
  subgraph Chain["HashKey Chain"]
    O[Price oracle<br/>PushOracle (testnet) / AggregatorV3 adapter] --> AV
    R[StrategyRegistry<br/>kill switch · paramsHash] --> AV
    AV[AgentVault<br/>risk limits · circuit breaker<br/>hash-chained log] <--> VN[IVenue<br/>SimVenue (testnet) / DEX adapter]
    F[VaultFactory] -.creates.-> AV
  end
  OWN((Owner)) -- deposit / withdraw / limits / resume --> AV
  AG((Agent key)) -- executeTrade / recordHold only --> AV
  AV -- "TradeExecuted / HoldRecorded events" --> VER[sentinel verify<br/>recompute log · re-hash decisions · NAV vs benchmark]
  D -. published files .-> VER
```

```
 owner ──deposit/withdraw/limits──▶ ┌───────────────────────────┐ ◀─ executeTrade / recordHold ── agent key
                                    │         AgentVault         │       (no withdraw, no config)
 StrategyRegistry ─ isActive ─────▶ │ size · volume · interval   │
 Oracle ─ price (fresh?) ─────────▶ │ slippage floor · drawdown  │ ──▶ venue (whitelisted)
                                    │ hash-chained decision log  │
                                    └───────────────────────────┘
```

## What's in the repo

| Path | What |
|---|---|
| `src/AgentVault.sol` | Core vault: roles, limits, circuit breaker, balance-delta fill accounting, hash-chained log |
| `src/StrategyRegistry.sol` | Strategy registry with author kill switch + params hash |
| `src/VaultFactory.sol` | Deploys vaults with the caller forced as owner |
| `src/oracles/` | `PushOracle` (testnet stand-in, move-bounded) and `AggregatorV3Oracle` (Chainlink-style adapter for production feeds) |
| `src/mocks/` | `MockERC20`, `SimVenue` (oracle-priced simulated exchange with fee + virtual depth) — **testnet only** |
| `test/` | 23 Foundry tests incl. fuzz (`TradeLossBounded`, `OwnerAlwaysWithdraws`), malicious-venue, stale-oracle, kill-switch, log-chain recompute |
| `agent/` | Python agent: signals, Hedge ensemble, optional LLM reviewer, runner, verifier, red-team probe, backtest, 8 pytest tests |
| `script/` | `DeployCore.s.sol` (mainnet: registry + factory + register strategy), `DeployDemo.s.sol` (testnet/local: full stack + funded vault) |
| `scripts/` | `demo_local.sh`, `deploy_testnet.sh`, `deploy_mainnet.sh` |
| `docs/` | Sample verification report + console output from a real run |

## The AI part (honest description)

The agent is an **online-learning ensemble**, not an LLM that "vibes" trades:

* Four experts per asset (trend/EMA, mean-reversion/RSI, breakout, a defensive "guard") each emit a score in [-1, 1].
* A **Hedge / multiplicative-weights** learner re-weights experts every tick from realised returns (no look-ahead; weights at *t* use data ≤ *t-1*).
* Scores → long-only target weights, **volatility-targeted**, capped per asset; orders are rebalances above a threshold, sized below the on-chain trade cap, with `minAmountOut` computed from the oracle with a safety margin inside the contract's slippage bound.
* **Optional LLM reviewer** (any OpenAI-compatible endpoint via `LLM_API_BASE/KEY/MODEL`): it may **veto or scale down** a proposal, never add risk (scale clamped to ≤ 1). Its raw answer and prompt hash are inside the hashed decision record. No key → fully deterministic.

## Quick start

```bash
# prerequisites: foundry (forge/anvil/cast), python 3.10+
git clone --recurse-submodules https://github.com/mesh-pch/sentinel-hashkey && cd sentinel-hashkey
pip install -r agent/requirements.txt

forge test                 # 23 contract tests (incl. fuzz)
make agent-test            # 8 agent tests
make backtest              # offline backtest on the committed 30-day hourly BTC/ETH fixture
make demo                  # anvil -> deploy -> 168 hourly ticks -> red-team probe -> verify -> tamper test
```

### Result of `make demo` (7 days of real hourly BTC/ETH prices, local anvil — see `docs/`)

| | |
|---|---|
| Log entries (all hash-chained) | 173 (16 trades + 157 holds) |
| Independent verification | **PASS** (chain recomputes, 168/168 decisions published & untampered, trades match declared orders) |
| Vault return / max drawdown | −0.55 % / 0.80 % |
| 50/50 BTC-ETH buy-and-hold, same window | −3.47 % |
| Trading cost (10 bps simulated venue fee) | $290 on $100k |
| Red-team probe | 90 %-of-NAV trade, `minOut=0`, unlisted venue, agent `withdraw()` → all rejected by the contract |
| Tamper test | edit a published rationale → `hash mismatch` → **FAIL** |

> The window was a falling market, so "lost less than buy-and-hold" is what a de-risking strategy should do; it is **not** evidence of alpha. 30-day offline backtest: −2.5 % vs −8.9 % buy-and-hold, 2.7 % max drawdown. We did not tune on future data, but we also make no profit claims — the point of the project is that *whatever* a strategy does, it is bounded and auditable.

### Deploying

```bash
# testnet (chain 133) — needs ~0.05 testnet HSK from https://faucet.hsk.xyz
OWNER_KEY_FILE=keys/owner_key AGENT_KEY_FILE=keys/agent_key bash scripts/deploy_testnet.sh

# mainnet (chain 177): StrategyRegistry + VaultFactory + register strategy
OWNER_KEY_FILE=keys/owner_key bash scripts/deploy_mainnet.sh
```

Measured on a mainnet fork: **4,236,667 gas ≈ 2.12 HSK** at the current 500 gwei base fee (+ ~0.0003 HSK L1 data fee). Foundry reserves `gasLimit × maxFee` (≈5.5 HSK) so hold ~6 HSK; only ~2.1 is spent.

### Live on HashKey Chain testnet (chain 133)

Demo vault: [`0xACdB76B454E9D845f650c0Ad30195E525856e01c`](https://testnet-explorer.hsk.xyz/address/0xACdB76B454E9D845f650c0Ad30195E525856e01c) · StrategyRegistry [`0xf25bc69c…ccd88`](https://testnet-explorer.hsk.xyz/address/0xf25bc69cb149258A1d95519E45020A68930ccd88) · VaultFactory [`0x4Eca5D66…15a8`](https://testnet-explorer.hsk.xyz/address/0x4Eca5D66529Dfc2cEB23f650Cc8f0fe0d2ae15a8). Full list, trade txs and a replayable verification in [`DEPLOYMENTS.md`](DEPLOYMENTS.md): 30 hash-chained log entries (4 trades, 26 holds), `verify` = PASS.

## Limitations / what's simulated (read this)

* `PushOracle` and `SimVenue` are **testnet stand-ins**: prices are pushed by the agent publisher (bounded per update) and the venue fills at oracle price ± fee/impact. A production deployment would use `AggregatorV3Oracle` over real feeds and an `IVenue` adapter for a real DEX; the vault's fill accounting (balance deltas) is venue-agnostic by design.
* Mainnet deployment contains the production components (registry + factory); the demo trading stack lives on testnet/local because integrating a real oracle feed + DEX adapter (and funding real liquidity) was out of scope for the hackathon window; the `IVenue` / `AggregatorV3Oracle` interfaces are where that plugs in.
* Long-only, two assets, one stable base asset. Not audited. Not financial advice. Do not deposit funds you cannot lose.
* The decision log proves *what the agent said it did and why*, and that it was not rewritten; it does not prove the reasoning was *good*.

## Security notes

Agent key can't withdraw (tested); owner can always withdraw, including when halted or oracle-stale (fuzzed); reentrancy-guarded; OpenZeppelin 5.x; Solidity 0.8.24 (`paris` EVM target for broad L2 compatibility).

## License

MIT
