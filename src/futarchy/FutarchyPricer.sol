// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPremiumPricer} from "../interfaces/IPremiumPricer.sol";
import {EventMarket} from "./EventMarket.sol";

/// @title FutarchyPricer
/// @notice Prices a premium from a prediction market: the market-implied probability of the insured
///         event IS the fair premium rate. Set it as a market's `premiumPricer` on the CoverApp so
///         the crowd, not an admin, prices risk. `floorRateWad` keeps a minimum premium.
contract FutarchyPricer is IPremiumPricer {
  mapping(bytes32 marketHash => EventMarket) public market;
  mapping(bytes32 marketHash => uint256) public floorRateWad;

  event Configured(bytes32 indexed marketHash, address eventMarket, uint256 floorRateWad);

  function configure(bytes32 marketHash, EventMarket eventMarket, uint256 _floorRateWad) external {
    market[marketHash] = eventMarket;
    floorRateWad[marketHash] = _floorRateWad;
    emit Configured(marketHash, address(eventMarket), _floorRateWad);
  }

  function quote(bytes32 marketHash, uint256 coverNotional, uint256, uint256) external view returns (uint256) {
    uint256 rate = market[marketHash].impliedProbabilityWad();
    uint256 floor = floorRateWad[marketHash];
    if (rate < floor) rate = floor;
    return coverNotional * rate / 1e18;
  }
}
