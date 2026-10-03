// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Wraps a Chainlink price feed as a Airbag IPriceOracle, with full staleness validation.
contract ChainlinkOracleAdapter is IPriceOracle {
  AggregatorV3Interface public immutable feed;

  error InvalidPrice();
  error StaleRound();

  constructor(address _feed) {
    feed = AggregatorV3Interface(_feed);
  }

  function decimals() external view returns (uint8) {
    return feed.decimals();
  }

  function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
    (uint80 roundId, int256 answer,, uint256 _updatedAt, uint80 answeredInRound) = feed.latestRoundData();
    if (answer <= 0) revert InvalidPrice();
    if (answeredInRound < roundId) revert StaleRound();
    return (uint256(answer), _updatedAt);
  }
}
