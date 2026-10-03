// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ITrigger} from "../interfaces/ITrigger.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title PriceGapTrigger
/// @notice A parametric trigger for RWA / tokenized-asset gap-down cover: pays a fraction of the
///         notional proportional to how far the insured asset's oracle price fell below a strike.
///         Plug it into a CoverApp market (Market.trigger) to underwrite proportional-loss cover on
///         tokenized stocks, LSTs, or any oracle-priced asset — not just a binary stablecoin depeg.
contract PriceGapTrigger is ITrigger {
  struct Config {
    address oracle;
    uint256 strike; // in the oracle's decimals; payout scales with the shortfall below this
    uint32 timeout;
    bool set;
  }

  uint256 internal constant BPS = 10_000;

  mapping(bytes32 marketHash => Config) public configs;

  event Configured(bytes32 indexed marketHash, address oracle, uint256 strike, uint32 timeout);

  error AlreadyConfigured();

  /// @notice Configure a market's gap parameters (first write wins).
  function configure(bytes32 marketHash, address oracle, uint256 strike, uint32 timeout) external {
    if (configs[marketHash].set) revert AlreadyConfigured();
    configs[marketHash] = Config({oracle: oracle, strike: strike, timeout: timeout, set: true});
    emit Configured(marketHash, oracle, strike, timeout);
  }

  function check(bytes32 marketHash, uint256) external view returns (bool triggered, uint256 payoutBps) {
    Config memory c = configs[marketHash];
    if (!c.set) return (false, 0);
    (uint256 price, uint256 updatedAt) = IPriceOracle(c.oracle).latestPrice();
    if (price == 0 || block.timestamp - updatedAt > c.timeout) return (false, 0);
    if (price >= c.strike) return (false, 0);
    payoutBps = (c.strike - price) * BPS / c.strike; // proportional loss, capped at BPS by CoverApp
    triggered = true;
  }
}
