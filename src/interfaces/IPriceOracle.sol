// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal price-oracle interface used by Airbag to detect depeg events.
/// @dev Chainlink-compatible subset. `price` is scaled by 10**decimals().
interface IPriceOracle {
  /// @return price The latest asset price (>0), scaled by `decimals()`.
  /// @return updatedAt The timestamp the price was last updated.
  function latestPrice() external view returns (uint256 price, uint256 updatedAt);

  /// @return The number of decimals in the returned price.
  function decimals() external view returns (uint8);
}
