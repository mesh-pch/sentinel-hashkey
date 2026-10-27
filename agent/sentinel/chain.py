"""Thin web3.py wrapper around the Sentinel contracts."""
from __future__ import annotations
import json, time
from pathlib import Path
from web3 import Web3
from web3.exceptions import ContractCustomError, ContractLogicError

ABI_DIR = Path(__file__).resolve().parent.parent / "abis"


def abi(name: str):
    return json.loads((ABI_DIR / f"{name}.json").read_text())


def read_key(path: str | Path) -> str:
    k = Path(path).read_text().strip()
    return k if k.startswith("0x") else "0x" + k


class Chain:
    def __init__(self, rpc: str, deployment: dict, key_path: str | None = None):
        self.w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 60}))
        self.dep = deployment
        self.chain_id = self.w3.eth.chain_id
        a = Web3.to_checksum_address
        self.vault = self.w3.eth.contract(a(deployment["AgentVault"]), abi=abi("AgentVault"))
        self.oracle = self.w3.eth.contract(a(deployment["PushOracle"]), abi=abi("PushOracle"))
        self.registry = self.w3.eth.contract(a(deployment["StrategyRegistry"]), abi=abi("StrategyRegistry"))
        self.account = self.w3.eth.account.from_key(read_key(key_path)) if key_path else None
        self.tokens = {k: a(deployment[v]) for k, v in (("USDT", "mUSDT"), ("BTC", "mWBTC"), ("ETH", "mWETH"))}
        self.dec = {t: self.w3.eth.contract(addr, abi=abi("MockERC20")).functions.decimals().call() for t, addr in self.tokens.items()}
        self.venue = a(deployment["SimVenue"])
        self._err = self._error_table()

    # ---------------------------------------------------------------- errors
    def _error_table(self) -> dict[str, str]:
        t = {}
        for item in abi("AgentVault"):
            if item["type"] == "error":
                sig = f"{item['name']}({','.join(i['type'] for i in item['inputs'])})"
                t["0x" + Web3.keccak(text=sig).hex().removeprefix("0x")[:8]] = item["name"]
        return t

    def decode_error(self, e: Exception) -> str:
        data = None
        if isinstance(e, ContractCustomError) and e.args:
            data = e.args[0]
        elif isinstance(e, ContractLogicError) and getattr(e, "data", None):
            data = e.data
        if isinstance(data, str) and data.startswith("0x") and len(data) >= 10:
            return self._err.get(data[:10], data[:10])
        return str(e)[:160]

    # ---------------------------------------------------------------- tx
    def send(self, fn, gas_pad: float = 1.3) -> dict:
        acct = self.account
        gas = int(fn.estimate_gas({"from": acct.address}) * gas_pad)
        tx = fn.build_transaction({"from": acct.address, "nonce": self.w3.eth.get_transaction_count(acct.address, "pending"),
                                   "gas": gas, "gasPrice": self.w3.eth.gas_price, "chainId": self.chain_id})
        signed = acct.sign_transaction(tx)
        h = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        rc = self.w3.eth.wait_for_transaction_receipt(h, timeout=180)
        if rc["status"] != 1:
            raise RuntimeError(f"tx reverted {h.hex()}")
        return {"hash": "0x" + h.hex().removeprefix("0x"), "block": rc["blockNumber"], "gasUsed": rc["gasUsed"]}

    # ---------------------------------------------------------------- reads
    def to_units(self, asset: str, amount: float) -> int:
        return int(amount * 10 ** self.dec[asset])

    def from_units(self, asset: str, raw: int) -> float:
        return raw / 10 ** self.dec[asset]

    def balances(self) -> dict[str, float]:
        return {a: self.from_units(a, self.w3.eth.contract(t, abi=abi("MockERC20")).functions.balanceOf(self.vault.address).call())
                for a, t in self.tokens.items()}

    def balances_raw(self) -> dict[str, int]:
        return {a: self.w3.eth.contract(t, abi=abi("MockERC20")).functions.balanceOf(self.vault.address).call()
                for a, t in self.tokens.items()}

    def nav_usd(self) -> float:
        return self.vault.functions.nav().call() / 10 ** self.dec["USDT"]

    def limits(self):
        l = self.vault.functions.limits().call()
        from .risk import Limits
        return Limits(*l)

    def oracle_prices(self) -> dict[str, float]:
        return {a: self.oracle.functions.getPrice(t).call()[0] / 1e18 for a, t in self.tokens.items()}

    def publish_prices(self, prices: dict[str, float]) -> dict:
        toks = [self.tokens["USDT"]] + [self.tokens[a] for a in prices]
        px = [10**18] + [int(p * 1e18) for p in prices.values()]
        return self.send(self.oracle.functions.setPrices(toks, px))

    def warp(self, seconds: int):
        """anvil only: advance the chain clock so a replay of hourly candles is realistic."""
        self.w3.provider.make_request("evm_increaseTime", [seconds])
        self.w3.provider.make_request("evm_mine", [])
