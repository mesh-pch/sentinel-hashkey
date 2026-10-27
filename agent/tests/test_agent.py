import copy, json
from pathlib import Path
from sentinel import decision, llm
from sentinel.backtest import backtest
from sentinel.brain import Brain
from sentinel.config import AGENT_PARAMS, canonical, params_hash
from sentinel.risk import Limits, clip_to_limit, precheck
from sentinel.signals import ema, rsi


def test_canonical_is_stable_and_hash_is_keccak():
    assert canonical({"b": 1, "a": [1.5, "x"]}) == '{"a":[1.5,"x"],"b":1}'
    assert params_hash() == params_hash() and params_hash().startswith("0x") and len(params_hash()) == 66


def test_decision_seal_roundtrip_and_tamper_detection(tmp_path: Path):
    rec = {"tick": 1, "rationale": "buy BTC", "orders": []}
    h = decision.save(tmp_path, rec)
    assert decision.rehash_file(tmp_path, h) == h
    f = tmp_path / f"{h}.json"
    f.write_text(f.read_text().replace("buy", "sell"))
    assert decision.rehash_file(tmp_path, h) != h


def test_signals_basic():
    assert ema([1, 1, 1, 1], 3) == 1
    assert rsi([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]) == 100


def test_brain_long_only_and_capped():
    b = Brain(AGENT_PARAMS)
    up = {a: [100 * 1.002 ** i for i in range(200)] for a in AGENT_PARAMS["assets"]}
    down = {a: [100 * 0.998 ** i for i in range(200)] for a in AGENT_PARAMS["assets"]}
    for h in (up, down):
        out = b.decide(h)
        for a, w in out["target_weights"].items():
            assert 0 <= w <= AGENT_PARAMS["max_alloc_per_asset"]
    assert sum(b.decide(down)["target_weights"].values()) <= sum(b.decide(up)["target_weights"].values())


def test_hedge_weights_normalised_and_floored():
    b = Brain(AGENT_PARAMS)
    hist = {a: [100 + i for i in range(120)] for a in AGENT_PARAMS["assets"]}
    for _ in range(30):
        b.decide(hist)
        b.learn({a: 100.0 for a in hist}, {a: 103.0 for a in hist})
    assert abs(sum(b.w.values()) - 1) < 1e-9
    assert min(b.w.values()) >= AGENT_PARAMS["hedge_floor"] * 0.9


def test_risk_mirror():
    L = Limits(2500, 15000, 1000, 100, 20, 3600)
    assert precheck(L, 100_000, 30_000, 0, 999) == "trade_too_large"
    assert precheck(L, 100_000, 10_000, 145_000, 999) == "daily_volume"
    assert precheck(L, 100_000, 10_000, 0, 5) == "min_interval"
    assert precheck(L, 100_000, 10_000, 0, 999) is None
    assert clip_to_limit(L, 100_000, 90_000) < 25_000


def test_llm_disabled_without_env(monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    assert not llm.enabled()


def test_backtest_runs_and_beats_bearish_buy_and_hold():
    r = backtest()
    assert r["max_dd_pct"] < 10
    assert r["return_pct"] > r["bench_5050_pct"]
