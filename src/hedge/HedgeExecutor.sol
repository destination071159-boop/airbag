// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice A perp/derivatives venue the hedger can short on to offset an underwriter's tail risk.
interface IHedgeVenue {
  function openShort(address asset, uint256 notional) external returns (uint256 positionId);
  function closeShort(uint256 positionId) external returns (int256 pnl);
}

/// @title HedgeExecutor
/// @notice Auto-hedging for underwriters: when the insured asset's risk spikes, a keeper calls
///         `hedge()` to open an offsetting short on a perp venue, capping the reserve's tail loss;
///         `unhedge()` closes it. The keeper (off-chain) decides WHEN based on a vol oracle; this
///         contract is the on-chain execution + bookkeeping. Only an authorized keeper may act.
contract HedgeExecutor {
  IHedgeVenue public immutable venue;
  address public immutable owner;
  mapping(address keeper => bool) public isKeeper;
  mapping(uint256 positionId => uint256 notional) public openNotional;

  event Hedged(address indexed asset, uint256 notional, uint256 positionId);
  event Unhedged(uint256 indexed positionId, int256 pnl);
  event KeeperSet(address indexed keeper, bool allowed);

  error NotOwner();
  error NotKeeper();

  constructor(IHedgeVenue _venue, address _owner) {
    venue = _venue;
    owner = _owner;
    isKeeper[_owner] = true;
  }

  function setKeeper(address keeper, bool allowed) external {
    if (msg.sender != owner) revert NotOwner();
    isKeeper[keeper] = allowed;
    emit KeeperSet(keeper, allowed);
  }

  /// @notice Open an offsetting short of `notional` on `asset` (keeper-triggered on a vol spike).
  function hedge(address asset, uint256 notional) external returns (uint256 positionId) {
    if (!isKeeper[msg.sender]) revert NotKeeper();
    positionId = venue.openShort(asset, notional);
    openNotional[positionId] = notional;
    emit Hedged(asset, notional, positionId);
  }

  /// @notice Close a hedge (keeper-triggered when risk subsides).
  function unhedge(uint256 positionId) external returns (int256 pnl) {
    if (!isKeeper[msg.sender]) revert NotKeeper();
    pnl = venue.closeShort(positionId);
    delete openNotional[positionId];
    emit Unhedged(positionId, pnl);
  }
}
