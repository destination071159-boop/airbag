// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {CoverApp} from "../src/CoverApp.sol";
import {CoverNote} from "../src/CoverNote.sol";
import {SolventBook} from "../src/SolventBook.sol";
import {YieldReserve} from "../src/YieldReserve.sol";
import {IReserveHook} from "../src/interfaces/IReserveHook.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {DripVault} from "../src/mocks/DripVault.sol";

/// @notice Auto-payout (keeper pushes the payout to the current note holder) on a yield-bearing
///         reserve: the underwriter earns vault APR + premiums, and the insured never clicks claim.
contract AutoPayoutTest is Test {
  Aqua aqua;
  CoverApp cover;
  CoverNote note;
  MockERC20 usdg;
  MockOracle oracle;
  DripVault vault;
  YieldReserve reserve;
  bytes32 hash;

  address underwriter = makeAddr("underwriter");
  address buyer = makeAddr("buyer");
  address friend = makeAddr("friend");
  address keeper = makeAddr("keeper");

  uint256 constant RESERVE = 1_000_000e18;

  function setUp() public {
    aqua = new Aqua();
    cover = new CoverApp(IAqua(address(aqua)), address(this));
    note = new CoverNote(address(cover));
    cover.initialize(note, SolventBook(address(0)));
    usdg = new MockERC20("Global Dollar", "USDG");
    oracle = new MockOracle(8, 1e8);
    vault = new DripVault(IERC20(address(usdg)), 450); // 4.5% APR
    reserve = new YieldReserve(underwriter, address(cover), IERC20(address(usdg)), IERC4626(address(vault)));

    CoverApp.Market memory m = CoverApp.Market({
      underwriter: address(reserve),
      asset: address(usdg),
      oracle: address(oracle),
      pegPrice: 1e8,
      depegBps: 300,
      maxUtilBps: 8000,
      oracleTimeout: 1 days,
      startRateWad: 0.01e18,
      endRateWad: 0.1e18,
      convexityWad: 1e18,
      trigger: address(0),
      salt: bytes32(uint256(1))
    });
    vm.startPrank(underwriter);
    usdg.mint(underwriter, RESERVE);
    usdg.approve(address(reserve), RESERVE);
    reserve.deposit(RESERVE);
    reserve.approveAqua(address(aqua));
    address[] memory tokens = new address[](1);
    tokens[0] = address(usdg);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = RESERVE;
    hash = abi.decode(
      reserve.execute(address(aqua), abi.encodeCall(IAqua.ship, (address(cover), abi.encode(m), tokens, amounts))),
      (bytes32)
    );
    reserve.execute(address(cover), abi.encodeCall(CoverApp.registerMarket, (m)));
    reserve.execute(address(cover), abi.encodeCall(CoverApp.setReserveHook, (IReserveHook(address(reserve)))));
    vm.stopPrank();
  }

  function _buy(uint256 notional) internal returns (uint256 id) {
    vm.startPrank(buyer);
    uint256 premium = cover.quotePremiumFor(hash, notional, 30 days);
    usdg.mint(buyer, premium);
    usdg.approve(address(cover), premium);
    id = cover.buyPolicy(hash, notional, 30 days);
    vm.stopPrank();
  }

  function test_keeper_pushes_payout_to_current_holder() public {
    uint256 id = _buy(100_000e18);
    assertEq(note.holderOf(id), buyer);

    // cover is assigned to a friend
    vm.prank(buyer);
    note.transfer(friend, id, 1);
    assertEq(note.holderOf(id), friend, "holder follows the note");

    // nothing to pay while the peg holds
    vm.prank(keeper);
    vm.expectRevert();
    cover.payout(id);

    // depeg: the keeper fires it; the friend receives USDG without sending any transaction
    oracle.set(0.93e8);
    vm.prank(keeper);
    uint256 paid = cover.payout(id);
    assertEq(paid, 100_000e18);
    assertEq(usdg.balanceOf(friend), 100_000e18, "paid to the holder, not the keeper");
    assertEq(usdg.balanceOf(keeper), 0);
    assertEq(note.holderOf(id), address(0), "note burned");

    // can't be paid twice
    vm.expectRevert(CoverApp.NotNoteHolder.selector); // burned note has no holder
    cover.payout(id);
  }

  function test_reserve_earns_vault_apr_and_premium() public {
    uint256 id = _buy(200_000e18);
    uint256 premium = usdg.balanceOf(address(reserve)); // premiums land liquid in the reserve

    vm.warp(block.timestamp + 29 days);
    uint256 yield = reserve.totalAssets() - RESERVE - premium;
    assertApproxEqRel(yield, RESERVE * 450 * 29 days / (10_000 * 365 days), 0.001e18, "4.5% APR accrues on the reserve");

    // a payout JIT-withdraws from the vault (minting the accrued yield first)
    oracle.set(0.9e8);
    vm.prank(keeper);
    cover.payout(id);
    assertEq(usdg.balanceOf(buyer), 200_000e18);
    assertGt(vault.totalYield(), 0, "yield realized on withdraw");
  }

  function test_premium_scales_with_term() public view {
    uint256 week = cover.quotePremiumFor(hash, 100_000e18, 7 days);
    uint256 month = cover.quotePremiumFor(hash, 100_000e18, 28 days);
    uint256 year = cover.quotePremium(hash, 100_000e18);
    assertApproxEqAbs(month, week * 4, 4, "4 weeks cost 4x one week");
    assertApproxEqAbs(year, cover.quotePremiumFor(hash, 100_000e18, 365 days), 1, "quotePremium = one year");
    assertLt(week, year / 50, "a week is ~1/52 of the annual premium");
  }
}
