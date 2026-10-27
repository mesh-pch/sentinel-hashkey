"""Main agent loop: observe -> learn -> decide -> seal decision -> (trade | hold) on-chain."""
from __future__ import annotations
import json, time
from pathlib import Path
from . import decision as dec, llm, market
from .brain import Brain
from .chain import Chain
from .config import AGENT_PARAMS, ASSETS, params_hash
from .risk import clip_to_limit, precheck

WARMUP = 96


def run_dir(chain: Chain) -> Path:
    return Path("runs") / f"{chain.chain_id}-{chain.vault.address.lower()[2:10]}"


def load_state(d: Path) -> dict:
    f = d / "state.json"
    return json.loads(f.read_text()) if f.exists() else {"tick": 0, "weights": None, "prev_prices": None, "trades": []}


def save_state(d: Path, st: dict) -> None:
    d.mkdir(parents=True, exist_ok=True)
    (d / "state.json").write_text(json.dumps(st))


def fair_out_raw(chain: Chain, tin: str, tout: str, amount_in_raw: int, prices_raw: dict[str, int]) -> int:
    return amount_in_raw * prices_raw[tin] * 10 ** chain.dec[tout] // (prices_raw[tout] * 10 ** chain.dec[tin])


def build_orders(chain: Chain, brain_out: dict, prices: dict[str, float], nav: float, bal: dict[str, float], limits, prm) -> list[dict]:
    thr = prm["rebalance_threshold"]
    sells, buys = [], []
    for a in ASSETS:
        cur_val = bal[a] * prices[a]
        tgt_val = brain_out["target_weights"][a] * nav
        delta = tgt_val - cur_val
        if abs(delta) < thr * nav or abs(delta) < prm["min_trade_value_usd"]:
            continue
        val = clip_to_limit(limits, nav, abs(delta))
        if delta < 0:
            amt = min(bal[a], val / prices[a])
            sells.append((a, amt, val))
        else:
            buys.append((a, val / 1.0, val))
    cash = bal["USDT"] + sum(v for _, _, v in sells) * 0.995
    orders = []
    prices_raw = {t: int(round(p * 1e18)) for t, p in {**prices, "USDT": 1.0}.items()}
    for a, amt, val in sells:
        raw = min(chain.to_units(a, amt), chain.balances_raw()[a])
        orders.append(_order(chain, "sell", a, a, "USDT", raw, val, prices_raw, limits, "target weight below current"))
    for a, usd, val in buys:
        usd = min(usd, cash)
        if usd < prm["min_trade_value_usd"]:
            continue
        cash -= usd
        orders.append(_order(chain, "buy", a, "USDT", a, chain.to_units("USDT", usd), usd, prices_raw, limits, "target weight above current"))
    return orders


def _order(chain, side, asset, tin, tout, raw_in, value, prices_raw, limits, why):
    fair = fair_out_raw(chain, tin, tout, raw_in, prices_raw)
    tol = limits.max_slippage_bps - AGENT_PARAMS["slippage_margin_bps"]
    return {"side": side, "asset": asset, "tokenIn": tin, "tokenOut": tout, "amountInRaw": str(raw_in),
            "minAmountOutRaw": str(fair * (10_000 - tol) // 10_000), "valueUsd": round(value, 2), "why": why}


def explain(brain_out, orders, prices) -> str:
    top = max(brain_out["scores"], key=lambda a: abs(brain_out["scores"][a]))
    ew = brain_out["expert_weights"]
    lead = max(ew, key=ew.get)
    if not orders:
        return (f"Hold. Strongest signal is {top} (score {brain_out['scores'][top]:+.2f}); portfolio already within "
                f"rebalance threshold of target. Leading expert: {lead} ({ew[lead]:.0%}).")
    return (f"{len(orders)} order(s): " + "; ".join(f"{o['side']} {o['asset']} ~${o['valueUsd']}" for o in orders)
            + f". Ensemble leans on {lead} ({ew[lead]:.0%}); scores " + ", ".join(f"{a} {s:+.2f}" for a, s in brain_out["scores"].items()) + ".")


def run(chain: Chain, mode: str, ticks: int, warp: bool, interval: int, hold_log: bool, start_offset: int | None = None, log=print) -> dict:
    prm = AGENT_PARAMS
    d = run_dir(chain)
    st = load_state(d)
    brain = Brain(prm, st["weights"])
    ph = params_hash()
    limits = chain.limits()
    fx = market.load_fixture()
    n = len(fx[ASSETS[0]])
    base = start_offset if start_offset is not None else n - ticks - 1
    summary = {"trades": 0, "holds": 0, "skipped": 0, "failed": 0, "tx": []}

    for k in range(ticks):
        i = base + k
        if mode == "replay":
            hist = {a: [p for _, p in fx[a][: i + 1]] for a in ASSETS}
            ts_market = fx[ASSETS[0]][i][0]
            prices = {a: hist[a][-1] for a in ASSETS}
            if warp and k > 0:
                chain.warp(3600)
        else:
            live = market.fetch_live_prices(ASSETS)
            hist = {a: [p for _, p in fx[a]] + [live[a]] for a in ASSETS}
            prices, ts_market = live, int(time.time())
            if k > 0:
                time.sleep(interval)

        chain.publish_prices(prices)
        if st["prev_prices"]:
            brain.learn(st["prev_prices"], prices)
        nav = chain.nav_usd()
        bal = chain.balances()
        weights_now = {a: round(bal[a] * prices[a] / nav, 6) for a in ASSETS}
        out = brain.decide(hist)
        now = chain.w3.eth.get_block("latest")["timestamp"]
        orders = build_orders(chain, out, prices, nav, bal, limits, prm)

        # client-side risk mirror (informational; the contract is the real gate)
        day_vol = sum(v for t, v in st["trades"] if now - t < 86400)
        since = now - (st["trades"][-1][0] if st["trades"] else 0)
        kept, skipped = [], []
        for o in orders:
            reason = precheck(limits, nav, o["valueUsd"], day_vol, since if not kept else 999)
            if reason:
                skipped.append({**o, "skippedBecause": reason})
            else:
                kept.append(o)
                day_vol += o["valueUsd"]

        review = None
        if kept and llm.enabled():
            try:
                review = llm.review({"prices": prices, "nav": nav, "brain": out, "orders": kept})
                if not review["approve"] or review["scale"] < 1.0:
                    sc = review["scale"]
                    for o in kept:
                        o["amountInRaw"] = str(int(int(o["amountInRaw"]) * sc))
                        o["minAmountOutRaw"] = str(int(int(o["minAmountOutRaw"]) * sc))
                        o["valueUsd"] = round(o["valueUsd"] * sc, 2)
                    kept = [o for o in kept if int(o["amountInRaw"]) > 0]
            except Exception as e:  # LLM failure never blocks or adds risk
                review = {"error": str(e)[:200]}

        record = {"schema": "sentinel.decision/1", "tick": st["tick"], "marketTs": ts_market, "chainId": chain.chain_id,
                  "vault": chain.vault.address, "strategy": {"id": chain.vault.functions.strategyId().call(), "paramsHash": ph},
                  "prices": prices, "portfolio": {"navUsd": round(nav, 4), "balances": bal, "weights": weights_now},
                  "brain": out, "orders": kept, "skipped": skipped, "llm": review,
                  "rationale": explain(out, kept, prices)}
        h = dec.save(d / "decisions", record)

        line = f"[tick {st['tick']:>3}] BTC {prices['BTC']:>9,.0f} ETH {prices['ETH']:>7,.0f} NAV ${nav:>10,.2f} "
        if kept:
            for j, o in enumerate(kept):
                if j > 0:   # contract enforces a minimum interval between trades: honour it instead of being rejected
                    (chain.warp(limits.min_interval_sec + 1) if (mode == "replay" and warp) else time.sleep(limits.min_interval_sec + 2))
                trade = (chain.venue, chain.tokens[o["tokenIn"]], chain.tokens[o["tokenOut"]], int(o["amountInRaw"]),
                         int(o["minAmountOutRaw"]), bytes.fromhex(h[2:]))
                try:
                    r = chain.send(chain.vault.functions.executeTrade(trade))
                    summary["trades"] += 1
                    summary["tx"].append(r["hash"])
                    st["trades"].append([r["timestamp"], o["valueUsd"]])
                    log(line + f"{o['side'].upper():4} {o['asset']} ${o['valueUsd']:>8,.0f} tx {r['hash'][:12]}.. dec {h[:10]}")
                except Exception as e:
                    summary["failed"] += 1
                    log(line + f"{o['side'].upper()} {o['asset']} REJECTED on-chain: {chain.decode_error(e)}")
        else:
            if skipped:
                summary["skipped"] += len(skipped)
            if hold_log:
                r = chain.send(chain.vault.functions.recordHold(bytes.fromhex(h[2:])))
                summary["holds"] += 1
                summary["tx"].append(r["hash"])
                log(line + f"HOLD  tx {r['hash'][:12]}.. dec {h[:10]}" + (f" (skipped {len(skipped)}: {skipped[0]['skippedBecause']})" if skipped else ""))
            else:
                log(line + "HOLD (not logged)")

        if kept and not (mode == "replay" and warp) and mode == "replay":
            time.sleep(limits.min_interval_sec + 2)   # real-time chain: respect the on-chain min interval before the next tick
        st["tick"] += 1
        st["weights"] = brain.w
        st["prev_prices"] = prices
        st["trades"] = st["trades"][-200:]
        save_state(d, st)
    summary["run_dir"] = str(d)
    return summary
