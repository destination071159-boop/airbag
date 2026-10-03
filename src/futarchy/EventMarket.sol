// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title EventMarket
/// @notice A minimal binary (YES/NO) prediction market — a constant-product AMM over outcome
///         reserves whose YES price IS the market-implied probability of the insured event. Used as
///         a price-discovery signal for `FutarchyPricer`. This is a virtual (signal-only) market;
///         a production version would collateralize positions.
contract EventMarket {
  uint256 public yesReserve;
  uint256 public noReserve;
  uint256 public immutable k;

  event Trade(bool indexed buyYes, uint256 amountIn, uint256 impliedProbabilityWad);

  constructor(uint256 seed) {
    yesReserve = seed;
    noReserve = seed;
    k = seed * seed;
  }

  /// @return probability of YES (the insured event occurring), in WAD. Rises as YES is bought.
  function impliedProbabilityWad() public view returns (uint256) {
    return noReserve * 1e18 / (yesReserve + noReserve);
  }

  /// @notice Buy YES exposure (bets the event WILL happen) — raises the implied probability.
  function buyYes(uint256 amountIn) external {
    uint256 newNo = noReserve + amountIn;
    yesReserve = k / newNo;
    noReserve = newNo;
    emit Trade(true, amountIn, impliedProbabilityWad());
  }

  /// @notice Buy NO exposure (bets the event will NOT happen) — lowers the implied probability.
  function buyNo(uint256 amountIn) external {
    uint256 newYes = yesReserve + amountIn;
    noReserve = k / newYes;
    yesReserve = newYes;
    emit Trade(false, amountIn, impliedProbabilityWad());
  }
}
