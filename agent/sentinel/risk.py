"""Client-side mirror of the on-chain risk checks. It lets the agent skip doomed transactions and explain why;
the contract remains the only enforcement point (this module is NOT trusted)."""
from __future__ import annotations
from dataclasses import dataclass

BPS = 10_000


@dataclass
class Limits:
    max_trade_bps: int
    max_daily_volume_bps: int
    max_drawdown_bps: int
    max_slippage_bps: int
    min_interval_sec: int
    max_oracle_age: int


def precheck(limits: Limits, nav: float, trade_value: float, day_volume: float, since_last_trade: float) -> str | None:
    if since_last_trade < limits.min_interval_sec:
        return "min_interval"
    if trade_value > nav * limits.max_trade_bps / BPS:
        return "trade_too_large"
    if day_volume + trade_value > nav * limits.max_daily_volume_bps / BPS:
        return "daily_volume"
    return None


def clip_to_limit(limits: Limits, nav: float, trade_value: float) -> float:
    return min(trade_value, nav * limits.max_trade_bps / BPS * 0.98)
