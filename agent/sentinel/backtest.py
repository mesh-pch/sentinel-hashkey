"""Fast offline backtest of the Brain on the fixture (no chain). Models a 10 bps venue fee and the 25%-NAV trade cap."""
from __future__ import annotations
import copy, sys
from . import market
from .brain import Brain
from .config import AGENT_PARAMS, ASSETS


def backtest(prm=AGENT_PARAMS, warmup=96, fee=0.001, max_trade=0.25, start=None, end=None):
    fx = market.load_fixture()
    px = {a: [p for _, p in fx[a]] for a in ASSETS}
    n = len(px["BTC"])
    s, e = (start if start is not None else warmup), (end if end is not None else n)
    brain, cash, units = Brain(prm), 100_000.0, {a: 0.0 for a in ASSETS}
    prev, curve, fees, trades = None, [], 0.0, 0
    for i in range(s, e):
        cur = {a: px[a][i] for a in ASSETS}
        if prev:
            brain.learn(prev, cur)
        nav = cash + sum(units[a] * cur[a] for a in ASSETS)
        out = brain.decide({a: px[a][: i + 1] for a in ASSETS})
        for a in ASSETS:       # sells first
            d = out["target_weights"][a] * nav - units[a] * cur[a]
            if d < -prm["rebalance_threshold"] * nav:
                v = min(-d, max_trade * nav, units[a] * cur[a]); units[a] -= v / cur[a]; cash += v * (1 - fee); fees += v * fee; trades += 1
        for a in ASSETS:
            d = out["target_weights"][a] * nav - units[a] * cur[a]
            if d > prm["rebalance_threshold"] * nav:
                v = min(d, max_trade * nav, cash); cash -= v; units[a] += v / cur[a] * (1 - fee); fees += v * fee; trades += 1
        prev = cur
        curve.append(cash + sum(units[a] * cur[a] for a in ASSETS))
    b0 = {a: px[a][s] for a in ASSETS}
    bench = 0.5 * px["BTC"][e - 1] / b0["BTC"] + 0.5 * px["ETH"][e - 1] / b0["ETH"]
    peak, mdd = 0, 0
    for v in curve:
        peak = max(peak, v); mdd = max(mdd, 1 - v / peak)
    return {"return_pct": round((curve[-1] / 100_000 - 1) * 100, 2), "bench_5050_pct": round((bench - 1) * 100, 2),
            "max_dd_pct": round(mdd * 100, 2), "trades": trades, "fees_usd": round(fees, 1)}


if __name__ == "__main__":
    for th in (0.02, 0.03, 0.05, 0.08):
        p = copy.deepcopy(AGENT_PARAMS); p["rebalance_threshold"] = th
        print("threshold", th, backtest(p))
    print("windows (current params):")
    for a, b in ((96, 300), (300, 500), (500, 721)):
        print(a, b, backtest(start=a, end=b))
