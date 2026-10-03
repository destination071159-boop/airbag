// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IReserveHook} from "./interfaces/IReserveHook.sol";

/// @title YieldReserve
/// @notice An underwriter's yield-bearing maker account. Reserve capital sits in an ERC-4626 vault
///         earning yield while ALSO backing Aqua cover (the `superposition` double-earn pattern).
///         Just-in-time before a claim, the CoverApp calls `onBeforePull` and this contract withdraws
///         exactly the payout from the vault so Aqua's `pull` succeeds — the reserve never has to sit
///         idle. The underwriter uses THIS contract's address as their Aqua maker.
contract YieldReserve is IReserveHook {
  using SafeERC20 for IERC20;

  address public immutable owner; // the underwriter
  address public immutable coverApp;
  IERC20 public immutable asset;
  IERC4626 public immutable vault;

  error NotOwner();
  error NotCoverApp();
  error WrongAsset();
  error CallFailed();

  modifier onlyOwner() {
    if (msg.sender != owner) revert NotOwner();
    _;
  }

  constructor(address _owner, address _coverApp, IERC20 _asset, IERC4626 _vault) {
    owner = _owner;
    coverApp = _coverApp;
    asset = _asset;
    vault = _vault;
    _asset.forceApprove(address(_vault), type(uint256).max);
  }

  /// @notice Approve Aqua (once) so it can `pull` payouts from this reserve.
  function approveAqua(address aqua) external onlyOwner {
    asset.forceApprove(aqua, type(uint256).max);
  }

  /// @notice Deposit `amount` of reserve capital into the yield vault.
  function deposit(uint256 amount) external onlyOwner {
    asset.safeTransferFrom(owner, address(this), amount);
    vault.deposit(amount, address(this));
  }

  /// @notice Withdraw `amount` of reserve capital from the vault back to the owner.
  function withdrawToOwner(uint256 amount) external onlyOwner {
    vault.withdraw(amount, owner, address(this));
  }

  /// @notice Yield-JIT: called by the CoverApp right before it pulls a payout.
  function onBeforePull(address _asset, uint256 amount) external {
    if (msg.sender != coverApp) revert NotCoverApp();
    if (_asset != address(asset)) revert WrongAsset();
    uint256 liquid = asset.balanceOf(address(this));
    if (liquid < amount) {
      vault.withdraw(amount - liquid, address(this), address(this));
    }
  }

  /// @notice Owner passthrough to ship/register/setReserveHook as this maker address.
  function execute(address target, bytes calldata data) external onlyOwner returns (bytes memory) {
    (bool ok, bytes memory ret) = target.call(data);
    if (!ok) revert CallFailed();
    return ret;
  }

  /// @notice Total reserve value: liquid balance + withdrawable vault assets (the real backing).
  function totalAssets() external view returns (uint256) {
    return asset.balanceOf(address(this)) + vault.maxWithdraw(address(this));
  }
}
