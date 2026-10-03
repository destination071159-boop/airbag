// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMessenger, IMessageReceiver} from "../crosschain/CrossChainCoverGateway.sol";

/// @notice Loopback messenger for tests: delivers synchronously (simulates a bridge round-trip).
contract MockMessenger is IMessenger {
  function send(uint32, address target, bytes calldata payload) external {
    IMessageReceiver(target).onMessage(uint32(block.chainid), payload);
  }
}
