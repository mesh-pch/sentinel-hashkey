#!/usr/bin/env bash
# One-command local demo: anvil -> deploy full stack -> agent replays 72h of real BTC/ETH prices -> red-team probe -> independent verify.
# Needs: foundry (forge, anvil), python3 with `pip install -r agent/requirements.txt`.
set -euo pipefail
cd "$(dirname "$0")/.."
TICKS=${TICKS:-72}
AGENT_KEY_FILE=${AGENT_KEY_FILE:-keys/agent_key}
mkdir -p keys deployments
# throwaway local keys (never used on a real network)
[ -f keys/agent_key ] || python3 -c "from eth_account import Account; print(Account.create().key.hex())" > keys/agent_key
AGENT_ADDRESS=$(python3 -c "from eth_account import Account; print(Account.from_key(open('keys/agent_key').read().strip()).address)")
ANVIL_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil's public dev key #0


pkill -f "anvil --port 8545" 2>/dev/null || true
anvil --port 8545 --silent & ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
sleep 2
cast rpc anvil_setBalance "$AGENT_ADDRESS" 0x56BC75E2D63100000 >/dev/null

read BTC0 ETH0 < <(python3 - <<PY
import json; d=json.load(open("agent/data/fixture_30d_hourly.json"))["prices"]; i=len(d["BTC"])-$TICKS-1
print(int(d["BTC"][i][1]), int(d["ETH"][i][1]))
PY
)
export PYTHONPATH=agent
PARAMS_HASH=$(python3 -m sentinel params-hash)
echo "== deploying (strategy paramsHash $PARAMS_HASH)"
PRIVATE_KEY=$ANVIL_PK AGENT_ADDRESS=$AGENT_ADDRESS BTC_PRICE_USD=$BTC0 ETH_PRICE_USD=$ETH0 STRATEGY_PARAMS_HASH=$PARAMS_HASH \
  forge script script/DeployDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -q
export RPC_URL=http://127.0.0.1:8545 DEPLOYMENT=deployments/31337.json AGENT_KEY_FILE
rm -rf runs
echo "== agent run (replay, $TICKS ticks, 1h chain time per tick)"
python3 -m sentinel run --mode replay --ticks "$TICKS" --warp
echo "== red-team probe"
python3 -m sentinel probe
echo "== independent verification"
python3 -m sentinel verify | tail -n 30
echo "report: $(ls runs/*/report.html)"
echo "== tamper test: rewrite one published decision's rationale after the fact"
F=$(ls runs/*/decisions/*.json | sed -n 5p)
cp "$F" /tmp/_decision_backup.json
sed -i 's/"rationale":"/"rationale":"(edited later) /' "$F"
python3 -m sentinel verify --no-write | grep -E "decisions_untampered|problems|VERIFICATION|hash mismatch" || true
cp /tmp/_decision_backup.json "$F"
