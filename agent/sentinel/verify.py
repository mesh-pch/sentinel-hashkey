"""Independent verifier: re-derives everything from public chain data + the published decision files.

Checks
  1. the on-chain hash-chained log (`logHead`) recomputes from event data alone, ids are gapless
  2. every decisionHash has a published decision file and keccak256(canonical(file)) == decisionHash
  3. every executed trade is consistent with the order the decision declared (tokens, size, min-out honoured)
  4. performance (NAV curve, return, max drawdown, trading cost) vs a buy-and-hold baseline built from the same prices
"""
from __future__ import annotations
import json, html
from pathlib import Path
from eth_abi import encode
from web3 import Web3
from . import decision as dec
from .chain import Chain

EXPLORER = {133: "https://testnet-explorer.hsk.xyz", 177: "https://hashkey.blockscout.com"}


def _h(b) -> str:
    return "0x" + (b.hex() if isinstance(b, (bytes, bytearray)) else bytes(b).hex()).removeprefix("0x")


def fetch_events(chain: Chain, name: str, from_block: int, chunk: int = 5000):
    latest = chain.w3.eth.block_number
    ev = getattr(chain.vault.events, name)
    out, s = [], from_block
    while s <= latest:
        e = min(latest, s + chunk - 1)
        out += list(ev.get_logs(from_block=s, to_block=e))
        s = e + 1
    return out


def verify(chain: Chain, rdir: Path, from_block: int, write: bool = True) -> dict:
    sym = {addr: s for s, addr in chain.tokens.items()}
    trades = fetch_events(chain, "TradeExecuted", from_block)
    holds = fetch_events(chain, "HoldRecorded", from_block)
    trips = fetch_events(chain, "CircuitBreakerTripped", from_block)
    entries = sorted([("trade", e) for e in trades] + [("hold", e) for e in holds],
                     key=lambda x: (x[1]["blockNumber"], x[1]["logIndex"]))
    checks, problems = {}, []

    # 1. hash chain
    head, ok_chain, ids_ok = b"\x00" * 32, True, True
    for n, (kind, e) in enumerate(entries, 1):
        a = e["args"]
        if a["id"] != n:
            ids_ok = False
        if kind == "trade":
            enc = encode(["bytes32", "uint256", "uint8", "bytes32", "address", "address", "uint256", "uint256", "uint256", "uint256"],
                         [head, a["id"], 1, a["decisionHash"], a["tokenIn"], a["tokenOut"], a["amountIn"], a["amountOut"], a["navAfter"], a["timestamp"]])
        else:
            enc = encode(["bytes32", "uint256", "uint8", "bytes32", "uint256", "uint256"],
                         [head, a["id"], 0, a["decisionHash"], a["nav"], a["timestamp"]])
        head = bytes(Web3.keccak(enc))
        if head != bytes(a["logHead"]):
            ok_chain = False
            problems.append(f"log entry {a['id']}: recomputed head differs from event head")
    onchain_head = bytes(chain.vault.functions.logHead().call())
    head_matches = (head == onchain_head) or not entries
    checks["hash_chain_recomputes"] = ok_chain and ids_ok and head_matches
    checks["log_entries"] = len(entries)

    # 2 + 3. decisions
    ddir = rdir / "decisions"
    seen, missing, tampered, mismatched = set(), [], [], []
    records: dict[str, dict] = {}
    for kind, e in entries:
        a = e["args"]
        dh = _h(a["decisionHash"])
        if dh not in seen:
            seen.add(dh)
            rec = dec.load(ddir, dh)
            if rec is None:
                missing.append(dh)
                continue
            if dec.rehash_file(ddir, dh) != dh:
                tampered.append(dh)
                continue
            records[dh] = rec
    for kind, e in entries:
        if kind != "trade":
            continue
        a = e["args"]
        rec = records.get(_h(a["decisionHash"]))
        if not rec:
            continue
        tin, tout = sym.get(a["tokenIn"]), sym.get(a["tokenOut"])
        match = [o for o in rec["orders"] if o["tokenIn"] == tin and o["tokenOut"] == tout and a["amountIn"] <= int(o["amountInRaw"])
                 and a["amountOut"] >= int(o["minAmountOutRaw"])]
        if not match:
            mismatched.append(a["id"])
    checks["decisions_published"] = not missing
    checks["decisions_untampered"] = not tampered
    checks["trades_match_declared_orders"] = not mismatched
    checks["decisions_checked"] = len(seen)
    for label, lst in (("missing decision file", missing), ("hash mismatch (file edited)", tampered), ("trade != declared order", mismatched)):
        for x in lst:
            problems.append(f"{label}: {x}")

    # 4. performance
    d6 = 10 ** chain.dec["USDT"]
    pts = []
    for kind, e in entries:
        a = e["args"]
        ts = a["timestamp"]
        nav = (a["navAfter"] if kind == "trade" else a["nav"]) / d6
        rec = records.get(_h(a["decisionHash"]))
        pts.append({"id": a["id"], "ts": ts, "nav": nav, "kind": kind, "prices": rec["prices"] if rec else None,
                    "tx": _h(e["transactionHash"]), "rationale": rec["rationale"] if rec else None})
    perf = {}
    if pts:
        nav0 = (trades[0]["args"]["navBefore"] / d6) if trades and trades[0]["blockNumber"] <= entries[0][1]["blockNumber"] else pts[0]["nav"]
        peak, mdd = nav0, 0.0
        for p in pts:
            peak = max(peak, p["nav"])
            mdd = max(mdd, 1 - p["nav"] / peak)
        priced = [p for p in pts if p["prices"]]
        bench = None
        if priced:
            p0 = priced[0]["prices"]
            for p in pts:
                if p["prices"]:
                    p["bench"] = nav0 * (0.5 * p["prices"]["BTC"] / p0["BTC"] + 0.5 * p["prices"]["ETH"] / p0["ETH"])
            bench = [p["bench"] for p in pts if "bench" in p][-1]
        cost = sum((e["args"]["navBefore"] - e["args"]["navAfter"]) for e in trades) / d6
        perf = {"startNav": round(nav0, 2), "endNav": round(pts[-1]["nav"], 2),
                "returnPct": round(100 * (pts[-1]["nav"] / nav0 - 1), 3), "maxDrawdownPct": round(100 * mdd, 3),
                "tradingCostUsd": round(cost, 2), "benchmark5050EndNav": round(bench, 2) if bench else None,
                "benchmark5050ReturnPct": round(100 * (bench / nav0 - 1), 3) if bench else None}
    res = {"vault": chain.vault.address, "chainId": chain.chain_id, "trades": len(trades), "holds": len(holds),
           "circuitBreakerTrips": len(trips), "checks": checks, "performance": perf, "problems": problems,
           "ok": all(v for k, v in checks.items() if isinstance(v, bool)),
           "logHead": _h(onchain_head)}
    if write:
        rdir.mkdir(parents=True, exist_ok=True)
        (rdir / "verification.json").write_text(json.dumps(res, indent=2))
        (rdir / "report.html").write_text(render_html(res, pts, chain.chain_id))
    return res


def render_html(res: dict, pts: list[dict], chain_id: int) -> str:
    ex = EXPLORER.get(chain_id, "")
    W, H = 760, 260
    series = [("Sentinel vault NAV", [p["nav"] for p in pts], "#2563eb"),
              ("50/50 BTC-ETH buy & hold", [p["bench"] for p in pts if "bench" in p], "#9ca3af")]
    allv = [v for _, s, _ in series for v in s] or [1, 2]
    lo, hi = min(allv), max(allv)
    span = (hi - lo) or 1

    def poly(vals, color):
        if len(vals) < 2:
            return ""
        step = (W - 40) / (len(vals) - 1)
        pts_ = " ".join(f"{20 + i * step:.1f},{H - 20 - (v - lo) / span * (H - 40):.1f}" for i, v in enumerate(vals))
        return f'<polyline fill="none" stroke="{color}" stroke-width="2" points="{pts_}"/>'

    svg = f'<svg width="{W}" height="{H}" style="background:#f8fafc;border:1px solid #e5e7eb">' + "".join(poly(s, c) for _, s, c in series) + "</svg>"
    legend = " ".join(f'<span style="color:{c}">&#9632; {html.escape(n)}</span>' for n, _, c in series)
    rows = "".join(
        f"<tr><td>{p['id']}</td><td>{p['kind']}</td><td>{p['nav']:,.2f}</td><td><a href='{ex}/tx/{p['tx']}'>{p['tx'][:12]}…</a></td><td>{html.escape(p['rationale'] or '')}</td></tr>"
        for p in pts[-40:])
    chk = "".join(f"<li>{'✅' if v is True else ('❌' if v is False else '•')} {k}: {v}</li>" for k, v in res["checks"].items())
    perf = "".join(f"<li>{k}: <b>{v}</b></li>" for k, v in res["performance"].items())
    return f"""<!doctype html><meta charset=utf-8><title>Sentinel verification</title>
<body style="font-family:system-ui;max-width:900px;margin:2em auto">
<h1>Sentinel — independent verification</h1>
<p>Vault <a href="{ex}/address/{res['vault']}">{res['vault']}</a> (chain {chain_id}) — overall: <b>{'PASS ✅' if res['ok'] else 'FAIL ❌'}</b></p>
<h3>Checks</h3><ul>{chk}</ul><h3>Performance</h3><ul>{perf}</ul>
<h3>Equity curve</h3><p>{legend}</p>{svg}
<h3>Latest log entries</h3><table border=1 cellpadding=4 style="border-collapse:collapse;font-size:13px"><tr><th>#</th><th>kind</th><th>NAV (USDT)</th><th>tx</th><th>agent rationale (hash-committed)</th></tr>{rows}</table>
<p>Problems: {html.escape('; '.join(res['problems']) or 'none')}</p></body>"""
