// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

/// @notice Demo v4 liquidity router that exposes the original caller like PositionManager does, so
///         CoverHook attributes the position to the real LP. Each LP gets its own position salt.
contract DemoLiquidityRouter is PoolModifyLiquidityTest, IMsgSender {
  address public msgSender;

  constructor(IPoolManager m) PoolModifyLiquidityTest(m) {}

  function modifyAs(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) external {
    msgSender = msg.sender;
    modifyLiquidity(
      key,
      ModifyLiquidityParams({
        tickLower: tickLower,
        tickUpper: tickUpper,
        liquidityDelta: liquidityDelta,
        salt: bytes32(uint256(uint160(msg.sender)))
      }),
      "",
      false,
      false
    );
    msgSender = address(0);
  }
}
