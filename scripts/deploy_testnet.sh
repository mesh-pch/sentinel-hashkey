#!/usr/bin/env bash
# Deploy the full demo stack to HashKey Chain TESTNET (chain id 133) and run the agent against it.
#   OWNER_KEY_FILE  : file with the owner/deployer private key (needs ~0.05 testnet HSK; faucet: https://faucet.hsk.xyz)
#   AGENT_KEY_FILE  : file with a separate agent key (gets a little HSK from the deployer automatically)
set -euo pipefail
cd "$(dirname "$0")/.."
RPC=${RPC_URL:-https://testnet.hsk.xyz}
OWNER_KEY_FILE=${OWNER_KEY_FILE:?set OWNER_KEY_FILE}
AGENT_KEY_FILE=${AGENT_KEY_FILE:?set AGENT_KEY_FILE}
TICKS=${TICKS:-48}
export PYTHONPATH=agent
OWNER_ADDR=$(cast wallet address --private-key "$(cat "$OWNER_KEY_FILE")")
AGENT_ADDR=$(cast wallet address --private-key "$(cat "$AGENT_KEY_FILE")")
echo "owner $OWNER_ADDR  agent $AGENT_ADDR  balance: $(cast balance "$OWNER_ADDR" --rpc-url "$RPC" --ether) HSK"
if [ "$(cast balance "$AGENT_ADDR" --rpc-url "$RPC")" = "0" ]; then
  cast send "$AGENT_ADDR" --value 0.02ether --private-key "$(cat "$OWNER_KEY_FILE")" --rpc-url "$RPC" >/dev/null
fi
read BTC0 ETH0 < <(python3 - <<PY
import json; d=json.load(open("agent/data/fixture_30d_hourly.json"))["prices"]; i=len(d["BTC"])-$TICKS-1
print(int(d["BTC"][i][1]), int(d["ETH"][i][1]))
PY
)
export PRIVATE_KEY=$(cat "$OWNER_KEY_FILE") AGENT_ADDRESS=$AGENT_ADDR BTC_PRICE_USD=$BTC0 ETH_PRICE_USD=$ETH0
export STRATEGY_PARAMS_HASH=$(python3 -m sentinel params-hash)
forge script script/DeployDemo.s.sol --rpc-url "$RPC" --broadcast --slow
unset PRIVATE_KEY
export RPC_URL=$RPC DEPLOYMENT=deployments/133.json AGENT_KEY_FILE
rm -rf runs
# testnet is real time: no warp; the replay still publishes one candle per tick
python3 -m sentinel run --mode replay --ticks "$TICKS"
python3 -m sentinel probe
python3 -m sentinel verify | tail -n 30
