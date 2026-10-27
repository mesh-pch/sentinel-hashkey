from __future__ import annotations
import argparse, json, os, sys
from pathlib import Path
from .chain import Chain
from .config import params_hash, canonical, AGENT_PARAMS


def _chain(a, need_key=True) -> Chain:
    dep = json.loads(Path(a.deployment).read_text())
    return Chain(a.rpc, dep, a.key if need_key else None)


def main(argv=None):
    p = argparse.ArgumentParser(prog="sentinel", description="Sentinel AI trading agent for HashKey Chain")
    p.add_argument("--rpc", default=os.getenv("RPC_URL", "http://127.0.0.1:8545"))
    p.add_argument("--deployment", default=os.getenv("DEPLOYMENT", "deployments/31337.json"))
    p.add_argument("--key", default=os.getenv("AGENT_KEY_FILE", "keys/agent_key"), help="file containing the AGENT private key (never the owner key)")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="run the agent loop")
    r.add_argument("--mode", choices=["replay", "live"], default="replay")
    r.add_argument("--ticks", type=int, default=48)
    r.add_argument("--warp", action="store_true", help="anvil only: advance chain time 1h per tick")
    r.add_argument("--interval", type=int, default=600, help="seconds between ticks in live mode")
    r.add_argument("--no-hold-log", action="store_true", help="do not write HOLD decisions on-chain")
    r.add_argument("--start-offset", type=int, default=None)
    v = sub.add_parser("verify", help="independently verify the on-chain log + published decisions")
    v.add_argument("--from-block", type=int, default=None)
    v.add_argument("--run-dir", default=None)
    v.add_argument("--no-write", action="store_true", help="do not overwrite verification.json / report.html")
    sub.add_parser("probe", help="red-team: show that the contract rejects unsafe trades")
    sub.add_parser("params-hash", help="print the strategy paramsHash to register on-chain")
    sub.add_parser("params", help="print canonical agent params")
    a = p.parse_args(argv)

    if a.cmd == "params-hash":
        print(params_hash()); return 0
    if a.cmd == "params":
        print(canonical(AGENT_PARAMS)); return 0
    if a.cmd == "run":
        from .runner import run
        c = _chain(a)
        s = run(c, a.mode, a.ticks, a.warp, a.interval, not a.no_hold_log, a.start_offset)
        print(json.dumps({k: v for k, v in s.items() if k != "tx"}, indent=2)); return 0
    if a.cmd == "verify":
        from .verify import verify
        from .runner import run_dir
        c = _chain(a, need_key=False)
        dep = json.loads(Path(a.deployment).read_text())
        fb = a.from_block if a.from_block is not None else int(dep.get("deployBlock", 0))
        res = verify(c, Path(a.run_dir) if a.run_dir else run_dir(c), fb, write=not a.no_write)
        print(json.dumps(res, indent=2))
        print("\nVERIFICATION:", "PASS" if res["ok"] else "FAIL")
        return 0 if res["ok"] else 2
    if a.cmd == "probe":
        from .probe import probe
        return probe(_chain(a))


if __name__ == "__main__":
    sys.exit(main())
