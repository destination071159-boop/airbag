// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISlippageSource} from "../triggers/SlippageRefundTrigger.sol";

/// @notice Settable realized-slippage source for tests (stands in for the v4 afterSwap recorder).
contract MockSlippageSource is ISlippageSource {
  mapping(bytes32 => mapping(uint256 => uint256)) public slippage;

  function set(bytes32 marketHash, uint256 policyId, uint256 bps) external {
    slippage[marketHash][policyId] = bps;
  }

  function realizedSlippageBps(bytes32 marketHash, uint256 policyId) external view returns (uint256) {
    return slippage[marketHash][policyId];
  }
}
