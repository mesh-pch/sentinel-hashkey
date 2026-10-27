"""The learning core: an online Hedge (multiplicative-weights) ensemble over the experts.

Every tick it (1) scores each asset with the weight-averaged expert signal, (2) turns scores into long-only target
weights with volatility targeting, (3) after the next candle arrives, updates expert weights by realised reward.
No look-ahead: weights used at tick t only depend on data up to t-1."""
from __future__ import annotations
import math
from .signals import all_signals, realized_vol, returns, clip


class Brain:
    def __init__(self, prm: dict, weights: dict[str, float] | None = None):
        self.prm = prm
        names = prm["experts"]
        self.w = dict(weights) if weights else {n: 1 / len(names) for n in names}
        self.last_signals: dict[str, dict[str, float]] | None = None   # asset -> expert -> score

    def learn(self, prev_prices: dict[str, float], new_prices: dict[str, float]) -> dict[str, float]:
        """Update expert weights with the realised return since the last decision."""
        if not self.last_signals:
            return self.w
        eta, floor = self.prm["hedge_eta"], self.prm["hedge_floor"]
        for e in self.w:
            reward = sum(self.last_signals[a][e] * (new_prices[a] / prev_prices[a] - 1) for a in self.last_signals)
            self.w[e] *= math.exp(eta * reward)
        z = sum(self.w.values())
        self.w = {e: max(floor, v / z) for e, v in self.w.items()}
        z = sum(self.w.values())
        self.w = {e: v / z for e, v in self.w.items()}
        return self.w

    def decide(self, history: dict[str, list[float]]) -> dict:
        prm = self.prm
        signals, scores, targets = {}, {}, {}
        for a in prm["assets"]:
            sg = all_signals(history[a], prm)
            signals[a] = sg
            scores[a] = sum(self.w[e] * sg[e] for e in self.w)
            vol = realized_vol(history[a])
            vscale = min(1.0, prm["target_hourly_vol"] / max(vol, 1e-6))
            targets[a] = round(clip(scores[a], 0, 1) * prm["max_alloc_per_asset"] * vscale, 6)
        self.last_signals = signals
        return {"signals": signals, "scores": {a: round(s, 6) for a, s in scores.items()},
                "expert_weights": {e: round(v, 6) for e, v in self.w.items()}, "target_weights": targets}
