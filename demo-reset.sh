#!/usr/bin/env bash
# Fresh local demo: restart anvil, redeploy every Airbag product (with a seeded book), restart the keeper.
# The frontend (npm run dev in ./frontend) picks up the new addresses automatically.
set -euo pipefail
cd "$(dirname "$0")"
LOGS=${LOGS:-/tmp/airbag-demo}
mkdir -p "$LOGS"

pkill -f "anvil --port 8545" 2>/dev/null || true
pkill -f "scripts/keeper.mjs" 2>/dev/null || true

nohup anvil --port 8545 --silent >"$LOGS/anvil.log" 2>&1 &
until cast block-number --rpc-url http://127.0.0.1:8545 >/dev/null 2>&1; do :; done

# anvil dev account #0 (public test key) deploys + underwrites
forge script script/DeployDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 >"$LOGS/deploy.log" 2>&1 \
  || { echo "deploy failed — see $LOGS/deploy.log"; exit 1; }
forge script script/AddMarketplace.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 >>"$LOGS/deploy.log" 2>&1 \
  || { echo "marketplace deploy failed — see $LOGS/deploy.log"; exit 1; }

(cd frontend && nohup node scripts/keeper.mjs >"$LOGS/keeper.log" 2>&1 &)
echo "Airbag demo ready: anvil :8545 · keeper log $LOGS/keeper.log · open http://localhost:3000/app (or your dev port)"
