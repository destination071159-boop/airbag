// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";

import {CoverApp} from "../src/CoverApp.sol";
import {CoverNote} from "../src/CoverNote.sol";
import {SolventBook} from "../src/SolventBook.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/// @notice End-to-end protocol lifecycle, start to finish, on a real Aqua:
///         underwriter opens a market -> buyers purchase cover -> policies lapse or pay out ->
///         capacity is recycled -> underwriter closes the market with a provable P&L.
contract LifecycleTest is Test {
  Aqua aqua;
  CoverApp cover;
  CoverNote note;
  MockERC20 usdg;
  MockOracle oracle;

  address underwriter = makeAddr("underwriter");
  address alice = makeAddr("alice");
  address bob = makeAddr("bob");
  address carol = makeAddr("carol");
  address keeper = makeAddr("keeper");

  uint256 constant RESERVE = 1_000_000e18;
  uint256 constant PEG = 1e8;

  function setUp() public {
    aqua = new Aqua();
    cover = new CoverApp(IAqua(address(aqua)), address(this));
    note = new CoverNote(address(cover));
    cover.initialize(note, SolventBook(address(0)));
    usdg = new MockERC20("Global Dollar", "USDG");
    oracle = new MockOracle(8, PEG);
  }

  // ── helpers ──────────────────────────────────────────────────────────

  function _market() internal view returns (CoverApp.Market memory) {
    return CoverApp.Market({
      underwriter: underwriter,
      asset: address(usdg),
      oracle: address(oracle),
      pegPrice: PEG,
      depegBps: 300, // pays out at <= $0.97
      maxUtilBps: 8000, // sell at most 80% of backing
      oracleTimeout: 1 hours,
      startRateWad: 0.01e18,
      endRateWad: 0.1e18,
      convexityWad: 1e18,
      trigger: address(0),
      salt: bytes32(uint256(1))
    });
  }

  /// Stage 1: the underwriter ships a USDG reserve into Aqua (it stays in their wallet) and opens a market.
  function _openMarket() internal returns (bytes32 hash) {
    CoverApp.Market memory m = _market();
    vm.startPrank(underwriter);
    usdg.mint(underwriter, RESERVE);
    usdg.approve(address(aqua), type(uint256).max);
    hash = aqua.ship(address(cover), abi.encode(m), _tokens(), _amounts(RESERVE));
    cover.registerMarket(m);
    vm.stopPrank();
  }

  function _buy(address who, bytes32 hash, uint256 notional, uint64 duration)
    internal
    returns (uint256 policyId, uint256 premium)
  {
    premium = cover.quotePremiumFor(hash, notional, duration);
    vm.startPrank(who);
    usdg.mint(who, premium);
    usdg.approve(address(cover), premium);
    policyId = cover.buyPolicy(hash, notional, duration);
    vm.stopPrank();
  }

  function _closeMarket(bytes32 hash) internal {
    vm.prank(underwriter);
    aqua.dock(address(cover), hash, _tokens());
  }

  function _tokens() internal view returns (address[] memory t) {
    t = new address[](1);
    t[0] = address(usdg);
  }

  function _amounts(uint256 a) internal pure returns (uint256[] memory x) {
    x = new uint256[](1);
    x[0] = a;
  }

  function _outstanding(bytes32 hash) internal view returns (uint256 covered) {
    (, covered,) = cover.solvency(hash);
  }

  // ── scenario A: calm period, no depeg ─────────────────────────────────

  /// Nothing goes wrong: every policy lapses, the underwriter keeps all premium, frees all
  /// capacity, and closes the market with reserve + premium in their own wallet.
  function test_lifecycle_calm_underwriter_earns_premium() public {
    bytes32 hash = _openMarket();

    (uint256 idA, uint256 premA) = _buy(alice, hash, 400_000e18, 30 days);
    (uint256 idB, uint256 premB) = _buy(bob, hash, 300_000e18, 60 days);
    uint256 premiums = premA + premB;

    assertEq(_outstanding(hash), 700_000e18);
    assertEq(usdg.balanceOf(underwriter), RESERVE + premiums, "premium lands in underwriter wallet");
    assertEq(cover.backingOf(hash), RESERVE + premiums, "Aqua backing tracks the wallet");

    // cannot expire early
    vm.expectRevert(CoverApp.PolicyNotExpired.selector);
    cover.expire(idA);

    // Alice's policy lapses; a keeper settles it permissionlessly
    vm.warp(block.timestamp + 30 days + 1);
    vm.prank(keeper);
    cover.expire(idA);
    assertEq(_outstanding(hash), 300_000e18, "Alice's cover released");

    // a lapsed note can no longer claim, even if a depeg happens later
    oracle.set(0.9e8);
    vm.prank(alice);
    vm.expectRevert(CoverApp.PolicyAlreadyClaimed.selector);
    cover.claim(idA);
    oracle.set(PEG);

    // cannot double-settle
    vm.expectRevert(CoverApp.PolicyAlreadyClaimed.selector);
    cover.expire(idA);

    // Bob's policy lapses too
    vm.warp(block.timestamp + 30 days);
    cover.expire(idB);
    assertEq(_outstanding(hash), 0, "all cover released");

    // underwriter exits: profit == premiums, no one else ever held the funds
    _closeMarket(hash);
    assertEq(usdg.balanceOf(underwriter) - RESERVE, premiums, "underwriter P&L = premiums");
    (uint248 bal,) = aqua.rawBalances(underwriter, address(cover), hash, address(usdg));
    assertEq(bal, 0, "market docked");
  }

  // ── scenario B: full lifecycle with capacity recycling and a depeg ────────

  function test_lifecycle_full_with_depeg() public {
    // 1. Underwriter opens the market
    bytes32 hash = _openMarket();
    (uint256 backing, uint256 covered, uint256 util) = cover.solvency(hash);
    assertEq(backing, RESERVE);
    assertEq(covered, 0);
    assertEq(util, 0);

    // 2. Buyers purchase cover; premium rises as the book fills
    uint256 firstQuote = cover.quotePremium(hash, 100_000e18);
    (uint256 idA, uint256 premA) = _buy(alice, hash, 400_000e18, 30 days);
    (uint256 idB, uint256 premB) = _buy(bob, hash, 300_000e18, 60 days);
    assertGt(cover.quotePremium(hash, 100_000e18), firstQuote, "premium rises with utilization");
    assertEq(note.balanceOf(alice, idA), 1);
    assertEq(note.balanceOf(bob, idB), 1);

    // 3. Book is near full: the solvency floor refuses to oversell
    vm.startPrank(carol);
    usdg.mint(carol, 100_000e18);
    usdg.approve(address(cover), type(uint256).max);
    vm.expectRevert();
    cover.buyPolicy(hash, 200_000e18, 30 days);
    vm.stopPrank();

    // 4. Alice's policy lapses quietly -> capacity is recycled -> Carol can now buy
    vm.warp(block.timestamp + 30 days + 1);
    vm.prank(keeper);
    cover.expire(idA);
    assertEq(_outstanding(hash), 300_000e18);
    (uint256 idC, uint256 premC) = _buy(carol, hash, 200_000e18, 30 days);
    assertEq(_outstanding(hash), 500_000e18);

    // 5. Small wobble to $0.98 is inside the band: no payout
    oracle.set(0.98e8);
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(CoverApp.NotDepegged.selector, 0.98e8, 0.97e8));
    cover.claim(idB);

    // 6. Stale oracle cannot be used to claim
    vm.warp(block.timestamp + 2 hours);
    vm.prank(bob);
    vm.expectRevert(CoverApp.StaleOracle.selector);
    cover.claim(idB);

    // 7. Real depeg to $0.92: both live policies pay out in full, atomically, in USDG
    oracle.set(0.92e8);
    vm.prank(bob);
    uint256 payB = cover.claim(idB);
    vm.prank(carol);
    uint256 payC = cover.claim(idC);
    assertEq(payB, 300_000e18);
    assertEq(payC, 200_000e18);
    assertEq(usdg.balanceOf(bob), 300_000e18, "Bob paid");
    assertEq(note.balanceOf(bob, idB), 0, "note burned");
    assertEq(_outstanding(hash), 0);

    // no double claim
    vm.prank(bob);
    vm.expectRevert(CoverApp.NotNoteHolder.selector);
    cover.claim(idB);

    // 8. Provable solvency end-state: Aqua backing == wallet == reserve + premiums - payouts
    uint256 premiums = premA + premB + premC;
    uint256 payouts = payB + payC;
    uint256 expected = RESERVE + premiums - payouts;
    assertEq(cover.backingOf(hash), expected, "virtual backing matches accounting");
    assertEq(usdg.balanceOf(underwriter), expected, "wallet matches accounting");

    // 9. Underwriter closes the market
    _closeMarket(hash);
    (uint248 bal,) = aqua.rawBalances(underwriter, address(cover), hash, address(usdg));
    assertEq(bal, 0, "market docked");
    emit log_named_decimal_uint("premiums earned (USDG)", premiums, 18);
    emit log_named_decimal_uint("payouts made   (USDG)", payouts, 18);
  }
}
