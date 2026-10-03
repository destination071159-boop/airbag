// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Demo ERC-4626 savings vault that accrues a fixed APR in real time (stands in for a
///         USDG savings / lending vault on testnet). Yield is minted from the mock asset on accrual.
contract DripVault is ERC4626 {
  uint256 public immutable aprBps;
  uint256 public lastDrip;
  uint256 public totalYield; // cumulative yield minted into the vault

  constructor(IERC20 asset_, uint256 _aprBps) ERC4626(asset_) ERC20("Airbag Savings USDG", "sUSDG") {
    aprBps = _aprBps;
    lastDrip = block.timestamp;
  }

  /// @notice Yield accrued since the last drip, not yet minted.
  function pending() public view returns (uint256) {
    return super.totalAssets() * aprBps * (block.timestamp - lastDrip) / (10_000 * 365 days);
  }

  function totalAssets() public view override returns (uint256) {
    return super.totalAssets() + pending();
  }

  /// @notice Mint accrued yield into the vault (called automatically on deposit/withdraw).
  function drip() public {
    uint256 y = pending();
    lastDrip = block.timestamp;
    if (y > 0) {
      totalYield += y;
      MockERC20(asset()).mint(address(this), y);
    }
  }

  function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
    drip();
    super._deposit(caller, receiver, assets, shares);
  }

  function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
    internal
    override
  {
    drip();
    super._withdraw(caller, receiver, owner, assets, shares);
  }
}
