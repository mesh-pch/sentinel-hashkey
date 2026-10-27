"""Market data: CoinGecko (live / refresh), a committed 30-day hourly fixture (reproducible demo), or synthetic GBM."""
from __future__ import annotations
import json, math, random, time, urllib.request
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent.parent / "data" / "fixture_30d_hourly.json"
CG_IDS = {"BTC": "bitcoin", "ETH": "ethereum"}


def load_fixture(path: Path = FIXTURE) -> dict[str, list[tuple[int, float]]]:
    raw = json.loads(Path(path).read_text())["prices"]
    return {a: [(int(t), float(p)) for t, p in rows] for a, rows in raw.items()}


def synthetic(assets, n=400, seed=7, start=None) -> dict[str, list[tuple[int, float]]]:
    rnd = random.Random(seed)
    start = start or {"BTC": 80000.0, "ETH": 2400.0}
    out = {}
    t0 = 1_790_000_000
    for a in assets:
        p, rows, drift = start[a], [], 0.0
        for i in range(n):
            drift = 0.97 * drift + rnd.gauss(0, 0.0004)       # slowly varying regime
            p *= math.exp(drift + rnd.gauss(0, 0.005))
            rows.append((t0 + 3600 * i, round(p, 2)))
        out[a] = rows
    return out


def fetch_live_prices(assets) -> dict[str, float]:
    ids = ",".join(CG_IDS[a] for a in assets)
    url = f"https://api.coingecko.com/api/v3/simple/price?ids={ids}&vs_currencies=usd"
    req = urllib.request.Request(url, headers={"User-Agent": "sentinel-agent/1.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        d = json.load(r)
    return {a: float(d[CG_IDS[a]]["usd"]) for a in assets}


def refresh_fixture(path: Path = FIXTURE, days: int = 30) -> None:
    out = {}
    for a, cid in CG_IDS.items():
        url = f"https://api.coingecko.com/api/v3/coins/{cid}/market_chart?vs_currency=usd&days={days}"
        req = urllib.request.Request(url, headers={"User-Agent": "sentinel-agent/1.0"})
        with urllib.request.urlopen(req, timeout=30) as r:
            out[a] = [[int(t // 1000), round(p, 2)] for t, p in json.load(r)["prices"]]
        time.sleep(3)
    n = min(len(v) for v in out.values())
    out = {a: v[-n:] for a, v in out.items()}
    Path(path).write_text(json.dumps({"source": f"coingecko days={days}", "interval_s": 3600, "prices": out}, separators=(",", ":")))
