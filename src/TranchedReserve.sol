// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TranchedReserve
/// @notice Structured (reinsurance-style) underwriting: one Aqua reserve funded by a SENIOR and a
///         JUNIOR tranche. Junior takes first loss and earns a larger share of premium; senior is
///         protected up to its principal. This contract IS the Aqua maker — it holds the pooled USDG
///         (approved to Aqua), so premiums (Aqua `push`, +balance) and payouts (Aqua `pull`,
///         -balance) flow through it and are split by an on-chain waterfall NAV. No callbacks needed.
contract TranchedReserve {
  using SafeERC20 for IERC20;

  IERC20 public immutable asset;
  address public immutable owner;
  uint16 public immutable juniorProfitShareBps; // junior's share of net premium profit (> senior's)

  uint256 internal constant BPS = 10_000;

  uint256 public juniorPrincipal;
  uint256 public seniorPrincipal;
  mapping(address => uint256) public juniorShares;
  mapping(address => uint256) public seniorShares;
  uint256 public totalJuniorShares;
  uint256 public totalSeniorShares;

  event Deposited(bool indexed junior, address indexed who, uint256 amount, uint256 shares);
  event Redeemed(bool indexed junior, address indexed who, uint256 shares, uint256 amount);

  error NotOwner();
  error CallFailed();
  error NoShares();

  modifier onlyOwner() {
    if (msg.sender != owner) revert NotOwner();
    _;
  }

  constructor(IERC20 _asset, address _owner, uint16 _juniorProfitShareBps) {
    asset = _asset;
    owner = _owner;
    juniorProfitShareBps = _juniorProfitShareBps;
  }

  function balance() public view returns (uint256) {
    return asset.balanceOf(address(this));
  }

  /// @notice Current value of each tranche via the loss/profit waterfall.
  function trancheValues() public view returns (uint256 juniorValue, uint256 seniorValue) {
    uint256 bal = balance();
    uint256 principals = juniorPrincipal + seniorPrincipal;
    if (bal >= principals) {
      uint256 profit = bal - principals;
      uint256 jProfit = profit * juniorProfitShareBps / BPS;
      juniorValue = juniorPrincipal + jProfit;
      seniorValue = seniorPrincipal + (profit - jProfit);
    } else {
      uint256 loss = principals - bal;
      if (loss <= juniorPrincipal) {
        juniorValue = juniorPrincipal - loss; // junior absorbs first
        seniorValue = seniorPrincipal;
      } else {
        juniorValue = 0; // junior wiped, senior takes the remainder
        seniorValue = seniorPrincipal - (loss - juniorPrincipal);
      }
    }
  }

  function depositJunior(uint256 amount) external {
    (uint256 jVal,) = trancheValues();
    uint256 shares = totalJuniorShares == 0 || jVal == 0 ? amount : amount * totalJuniorShares / jVal;
    asset.safeTransferFrom(msg.sender, address(this), amount);
    juniorPrincipal += amount;
    juniorShares[msg.sender] += shares;
    totalJuniorShares += shares;
    emit Deposited(true, msg.sender, amount, shares);
  }

  function depositSenior(uint256 amount) external {
    (, uint256 sVal) = trancheValues();
    uint256 shares = totalSeniorShares == 0 || sVal == 0 ? amount : amount * totalSeniorShares / sVal;
    asset.safeTransferFrom(msg.sender, address(this), amount);
    seniorPrincipal += amount;
    seniorShares[msg.sender] += shares;
    totalSeniorShares += shares;
    emit Deposited(false, msg.sender, amount, shares);
  }

  function redeemJunior(uint256 shares) external returns (uint256 amount) {
    if (shares == 0 || totalJuniorShares == 0) revert NoShares();
    (uint256 jVal,) = trancheValues();
    amount = shares * jVal / totalJuniorShares;
    juniorPrincipal -= shares * juniorPrincipal / totalJuniorShares;
    juniorShares[msg.sender] -= shares;
    totalJuniorShares -= shares;
    asset.safeTransfer(msg.sender, amount);
    emit Redeemed(true, msg.sender, shares, amount);
  }

  function redeemSenior(uint256 shares) external returns (uint256 amount) {
    if (shares == 0 || totalSeniorShares == 0) revert NoShares();
    (, uint256 sVal) = trancheValues();
    amount = shares * sVal / totalSeniorShares;
    seniorPrincipal -= shares * seniorPrincipal / totalSeniorShares;
    seniorShares[msg.sender] -= shares;
    totalSeniorShares -= shares;
    asset.safeTransfer(msg.sender, amount);
    emit Redeemed(false, msg.sender, shares, amount);
  }

  /// @notice Approve Aqua (once) so it can pull payouts from the pooled reserve.
  function approveAqua(address aqua) external onlyOwner {
    asset.forceApprove(aqua, type(uint256).max);
  }

  /// @notice Owner passthrough so this contract can `ship`/`registerMarket` as the Aqua maker.
  function execute(address target, bytes calldata data) external onlyOwner returns (bytes memory) {
    (bool ok, bytes memory ret) = target.call(data);
    if (!ok) revert CallFailed();
    return ret;
  }
}
