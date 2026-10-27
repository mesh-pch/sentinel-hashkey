"""Optional LLM reviewer (any OpenAI-compatible endpoint). Safety rule: the LLM can only VETO or SCALE DOWN a proposal,
never increase risk, and its raw answer is stored in the decision record (and therefore hashed on-chain).
Configure with LLM_API_BASE, LLM_API_KEY, LLM_MODEL. Without them the agent runs fully deterministically."""
from __future__ import annotations
import hashlib, json, os, urllib.request

SYSTEM = ("You are the risk reviewer of an automated crypto trading agent on a testnet vault. You get a JSON proposal "
          "(prices, signals, proposed orders). Reply ONLY with JSON: {\"approve\": bool, \"scale\": number 0..1, "
          "\"rationale\": string <= 280 chars}. You may reduce or veto; you cannot add risk.")


def enabled() -> bool:
    return bool(os.getenv("LLM_API_KEY") and os.getenv("LLM_MODEL"))


def review(proposal: dict, timeout: float = 30.0) -> dict:
    base = os.getenv("LLM_API_BASE", "https://api.openai.com/v1").rstrip("/")
    payload = {"model": os.environ["LLM_MODEL"], "temperature": 0,
               "messages": [{"role": "system", "content": SYSTEM},
                            {"role": "user", "content": json.dumps(proposal, sort_keys=True)}]}
    body = json.dumps(payload).encode()
    req = urllib.request.Request(base + "/chat/completions", data=body, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + os.environ["LLM_API_KEY"]})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        text = json.load(r)["choices"][0]["message"]["content"]
    try:
        j = json.loads(text[text.index("{"): text.rindex("}") + 1])
        approve = bool(j.get("approve", True))
        scale = min(1.0, max(0.0, float(j.get("scale", 1.0))))     # clamp: can never exceed 1
        rationale = str(j.get("rationale", ""))[:280]
    except Exception:
        approve, scale, rationale = True, 1.0, "unparseable LLM answer ignored"
    return {"model": os.environ["LLM_MODEL"], "prompt_sha256": hashlib.sha256(body).hexdigest(),
            "approve": approve, "scale": scale if approve else 0.0, "rationale": rationale, "raw": text[:2000]}
