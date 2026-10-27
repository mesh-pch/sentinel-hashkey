"""Agent configuration. The canonical JSON of AGENT_PARAMS is hashed and committed in the on-chain StrategyRegistry
(`paramsHash`), so anyone can check that the agent that is trading is the agent that was registered."""
from __future__ import annotations
import json
from web3 import Web3

ASSETS = ["BTC", "ETH"]          # risky assets; the base asset is mUSDT (stable)
BASE = "USDT"
TOKEN_KEYS = {"USDT": "mUSDT", "BTC": "mWBTC", "ETH": "mWETH"}  # asset -> key in deployments json

AGENT_PARAMS = {
    "name": "Sentinel Hedge-Ensemble",
    "version": 1,
    "assets": ASSETS,
    "experts": ["trend", "meanrev", "breakout", "guard"],
    "ema_fast": 12, "ema_slow": 48, "rsi_period": 14, "breakout_window": 24, "guard_window": 72,
    "hedge_eta": 20.0, "hedge_floor": 0.02,
    "max_alloc_per_asset": 0.35, "target_hourly_vol": 0.006,
    "rebalance_threshold": 0.05, "min_trade_value_usd": 25.0,
    "slippage_margin_bps": 5,
    "llm_policy": "may only veto or scale DOWN a proposed trade; can never add risk",
}


def canonical(obj) -> str:
    """Language-neutral canonical JSON: sorted keys, no whitespace, UTF-8, shortest-repr floats."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def keccak_hex(text: str) -> str:
    return "0x" + Web3.keccak(text=text).hex().removeprefix("0x")


def params_hash() -> str:
    return keccak_hex(canonical(AGENT_PARAMS))
