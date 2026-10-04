#!/usr/bin/env bash
# Submit contract verification for the Arbitrum Sepolia deployment (reads keys from ./.env).
#   ./verify-sepolia.sh                 # Arbiscan (can sit "Pending in queue" for a long time)
#   VERIFIER=sourcify ./verify-sepolia.sh
set -uo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
F=frontend/src/lib/deployment.421614.json
a() { jq -r ".$1" "$F"; }
V() { # name path args...
  local addr=$1 id=$2; shift 2
  if [ "${VERIFIER:-etherscan}" = sourcify ]; then
    ETHERSCAN_API_KEY= forge verify-contract "$addr" "$id" --chain 421614 --compiler-version 0.8.30 --verifier sourcify "$@" 2>&1
  else
    forge verify-contract "$addr" "$id" --chain 421614 --compiler-version 0.8.30 \
      --etherscan-api-key "$ETHERSCAN_API_KEY" --watch --retries 30 --delay 15 "$@" 2>&1
  fi | grep -iE "pass|fail|verified|error|success|perfect|partial|Job ID|GUID" | tail -1 | sed "s#^#$id: #"
}
V "$(a aqua)"        lib/aqua/src/Aqua.sol:Aqua
V "$(a coverApp)"    src/CoverApp.sol:CoverApp            --constructor-args "$(cast abi-encode 'c(address,address)' "$(a aqua)" "$(a underwriter)")"
V "$(a coverNote)"   src/CoverNote.sol:CoverNote          --constructor-args "$(cast abi-encode 'c(address)' "$(a coverApp)")"
V "$(a ilTrigger)"   src/triggers/ILTrigger.sol:ILTrigger --constructor-args "$(cast abi-encode 'c(address)' "$(a coverApp)")"
V "$(a gapTrigger)"  src/triggers/PriceGapTrigger.sol:PriceGapTrigger
V "$(a coverRouter)" src/CoverRouter.sol:CoverRouter      --constructor-args "$(cast abi-encode 'c(address)' "$(a coverApp)")"
V "$(a hook)"        src/CoverHook.sol:CoverHook          --constructor-args "$(cast abi-encode 'c(address)' "$(a poolManager)")"
V "$(a yieldReserve)" src/YieldReserve.sol:YieldReserve   --constructor-args "$(cast abi-encode 'c(address,address,address,address)' "$(a underwriter)" "$(a coverApp)" "$(a usdg)" "$(a vault)")"
V "$(a vault)"       src/mocks/DripVault.sol:DripVault    --constructor-args "$(cast abi-encode 'c(address,uint256)' "$(a usdg)" 450)"
V "$(a usdg)"        src/mocks/MockERC20.sol:MockERC20    --constructor-args "$(cast abi-encode 'c(string,string)' 'Global Dollar' 'USDG')"
V "$(a oracle)"      src/mocks/MockOracle.sol:MockOracle  --constructor-args "$(cast abi-encode 'c(uint8,uint256)' 8 100000000)"
V "$(a stockOracle)" src/mocks/MockOracle.sol:MockOracle  --constructor-args "$(cast abi-encode 'c(uint8,uint256)' 8 25000000000)"
V "$(a lpRouter)"    src/mocks/DemoLiquidityRouter.sol:DemoLiquidityRouter --constructor-args "$(cast abi-encode 'c(address)' "$(a poolManager)")"
