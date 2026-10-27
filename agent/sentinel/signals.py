"""Pure-python technical experts. Each returns a score in [-1, 1] (long-only vault: negative = de-risk)."""
from __future__ import annotations
import math
from statistics import mean, pstdev


def ema(xs: list[float], n: int) -> float:
    k = 2 / (n + 1)
    e = xs[0]
    for x in xs[1:]:
        e = x * k + e * (1 - k)
    return e


def returns(xs: list[float]) -> list[float]:
    return [xs[i] / xs[i - 1] - 1 for i in range(1, len(xs))]


def realized_vol(xs: list[float], n: int = 48) -> float:
    r = returns(xs[-(n + 1):])
    return pstdev(r) if len(r) > 2 else 0.01


def rsi(xs: list[float], n: int = 14) -> float:
    r = returns(xs[-(n + 1):])
    up = sum(x for x in r if x > 0)
    dn = -sum(x for x in r if x < 0)
    if up + dn == 0:
        return 50.0
    return 100 * up / (up + dn)


def clip(x: float, lo=-1.0, hi=1.0) -> float:
    return max(lo, min(hi, x))


def expert_trend(p: list[float], prm) -> float:
    f, s = ema(p[-4 * prm["ema_slow"]:], prm["ema_fast"]), ema(p[-4 * prm["ema_slow"]:], prm["ema_slow"])
    sig = max(realized_vol(p), 1e-4)
    return math.tanh(((f / s) - 1) / (3 * sig))


def expert_meanrev(p: list[float], prm) -> float:
    return clip((50 - rsi(p, prm["rsi_period"])) / 30)


def expert_breakout(p: list[float], prm) -> float:
    w = p[-prm["breakout_window"]:]
    sd = pstdev(w) or 1e-9
    return clip((p[-1] - mean(w)) / (2 * sd))


def expert_guard(p: list[float], prm) -> float:
    hi = max(p[-prm["guard_window"]:])
    dd = 1 - p[-1] / hi
    return -1.0 if dd > 0.06 else (0.2 if dd < 0.02 else 0.0)


EXPERTS = {"trend": expert_trend, "meanrev": expert_meanrev, "breakout": expert_breakout, "guard": expert_guard}


def all_signals(p: list[float], prm) -> dict[str, float]:
    return {name: round(fn(p, prm), 6) for name, fn in EXPERTS.items()}
