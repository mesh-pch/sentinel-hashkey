"""Decision records: what the agent saw, thought and intends to do. The keccak256 of the canonical JSON is the
`decisionHash` that goes on-chain with the trade, so the reasoning cannot be rewritten after the fact."""
from __future__ import annotations
import json
from pathlib import Path
from .config import canonical, keccak_hex


def seal(record: dict) -> tuple[str, str]:
    c = canonical(record)
    return keccak_hex(c), c


def save(dirpath: Path, record: dict) -> str:
    h, c = seal(record)
    dirpath.mkdir(parents=True, exist_ok=True)
    (dirpath / f"{h}.json").write_text(c)
    return h


def load(dirpath: Path, h: str) -> dict | None:
    f = dirpath / f"{h}.json"
    return json.loads(f.read_text()) if f.exists() else None


def rehash_file(dirpath: Path, h: str) -> str | None:
    f = dirpath / f"{h}.json"
    if not f.exists():
        return None
    return keccak_hex(canonical(json.loads(f.read_text())))
