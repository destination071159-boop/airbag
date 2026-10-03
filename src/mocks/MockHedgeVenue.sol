// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHedgeVenue} from "../hedge/HedgeExecutor.sol";

/// @notice Mock perp venue for tests (stands in for Hyperliquid/GMX/etc.).
contract MockHedgeVenue is IHedgeVenue {
  uint256 public nextId;
  mapping(uint256 => uint256) public notionalOf;
  mapping(uint256 => bool) public open;
  int256 public pnlToReturn;

  function setPnl(int256 pnl) external {
    pnlToReturn = pnl;
  }

  function openShort(address, uint256 notional) external returns (uint256 positionId) {
    positionId = ++nextId;
    notionalOf[positionId] = notional;
    open[positionId] = true;
  }

  function closeShort(uint256 positionId) external returns (int256) {
    open[positionId] = false;
    return pnlToReturn;
  }
}
