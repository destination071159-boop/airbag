// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ITrigger} from "../interfaces/ITrigger.sol";

/// @notice Settable trigger for tests/demos of custom cover products.
contract MockTrigger is ITrigger {
  bool public triggered;
  uint256 public payoutBps;

  function set(bool _triggered, uint256 _payoutBps) external {
    triggered = _triggered;
    payoutBps = _payoutBps;
  }

  function check(bytes32, uint256) external view returns (bool, uint256) {
    return (triggered, payoutBps);
  }
}
