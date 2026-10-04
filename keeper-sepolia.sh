#!/usr/bin/env bash
# Keep the Airbag auto-payout keeper running on Arbitrum Sepolia (restarts on crash).
# Reads PRIVATE_KEY from ./.env inside this process — nothing secret goes on the command line.
#   ./keeper-sepolia.sh            # foreground
#   nohup ./keeper-sepolia.sh >/tmp/airbag-demo/keeper-sepolia.log 2>&1 &
set -uo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
export KEEPER_KEY="${PRIVATE_KEY}"
case "$KEEPER_KEY" in 0x*) ;; *) KEEPER_KEY="0x$KEEPER_KEY";; esac
export NETWORK=sepolia DEMO_FEED=1 INTERVAL_MS="${INTERVAL_MS:-5000}"
export RPC_URL="${KEEPER_RPC:-https://sepolia-rollup.arbitrum.io/rpc}"
unset PRIVATE_KEY ETHERSCAN_API_KEY
cd frontend
while true; do
  node scripts/keeper.mjs sepolia
  echo "[keeper-sepolia] exited ($?) — restarting in 5s"
  sleep 5
done
