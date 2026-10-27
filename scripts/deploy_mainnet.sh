#!/usr/bin/env bash
# Deploy the production-grade core (StrategyRegistry + VaultFactory + register Sentinel strategy) to HashKey Chain MAINNET (177).
# Exact cost measured on a mainnet fork: 4,236,667 gas  ->  ~2.12 HSK at the current 500 gwei base fee (+ ~0.0003 HSK L1 data fee).
# forge reserves gasLimit x maxFee (5.54M x 1000 gwei = 5.54 HSK) so the deployer should HOLD ~6 HSK; only ~2.1 is spent.
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONPATH=agent
OWNER_KEY_FILE=${OWNER_KEY_FILE:?set OWNER_KEY_FILE}
export PRIVATE_KEY=$(cat "$OWNER_KEY_FILE")
export STRATEGY_PARAMS_HASH=$(python3 -m sentinel params-hash)
export STRATEGY_URI=${STRATEGY_URI:-https://github.com/mesh-pch/sentinel-hashkey}
ADDR=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "deployer $ADDR balance $(cast balance "$ADDR" --rpc-url https://mainnet.hsk.xyz --ether) HSK"
forge script script/DeployCore.s.sol --rpc-url https://mainnet.hsk.xyz --broadcast --slow
