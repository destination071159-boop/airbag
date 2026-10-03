// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Optional hook an underwriter registers so their reserve can earn yield and be pulled
///         back just-in-time before a claim payout (the `superposition` capital-efficiency pattern).
interface IReserveHook {
  /// @notice Called by the CoverApp immediately before it `pull`s `amount` of `asset` from the
  ///         underwriter's wallet, so a yield-deployed reserve can top up liquid balance in time.
  function onBeforePull(address asset, uint256 amount) external;
}
