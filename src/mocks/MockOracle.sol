// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @notice Settable price oracle for tests/demos (stands in for Chainlink/Pyth).
contract MockOracle is IPriceOracle {
  uint256 public price;
  uint256 public updatedAt;
  uint8 public immutable decimals;

  constructor(uint8 _decimals, uint256 _price) {
    decimals = _decimals;
    price = _price;
    updatedAt = block.timestamp;
  }

  function set(uint256 _price) external {
    price = _price;
    updatedAt = block.timestamp;
  }

  function latestPrice() external view returns (uint256, uint256) {
    return (price, updatedAt);
  }
}
