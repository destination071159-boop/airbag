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

contract CoverAppTest is Test {
  Aqua aqua;
  CoverApp cover;
  CoverNote note;
  SolventBook book;
  MockERC20 usdg;
  MockOracle oracle;

  address underwriter = makeAddr("underwriter");
  address buyer = makeAddr("buyer");
  address bob = makeAddr("bob");

  uint256 constant RESERVE = 1_000_000e18;
  uint256 constant PEG = 1e8;

  function setUp() public {
    aqua = new Aqua();
    cover = new CoverApp(IAqua(address(aqua)), address(this));
    note = new CoverNote(address(cover));
    book = new SolventBook(address(this));
    cover.initialize(note, SolventBook(address(0))); // per-market floor only for these tests
    usdg = new MockERC20("Global Dollar", "USDG");
    oracle = new MockOracle(8, PEG);
  }

  function _market() internal view returns (CoverApp.Market memory m) {
    m = CoverApp.Market({
      underwriter: underwriter,
      asset: address(usdg),
      oracle: address(oracle),
      pegPrice: PEG,
      depegBps: 300, // trigger <= $0.97
      maxUtilBps: 8000, // cover up to 80% of backing
      oracleTimeout: 1 hours,
      startRateWad: 0.01e18, // 1% premium at 0% util
      endRateWad: 0.1e18, // 10% premium at full util
      convexityWad: 1e18, // linear
      trigger: address(0), // built-in depeg
      salt: bytes32(uint256(1))
    });
  }

  function _ship() internal returns (bytes32 hash) {
    CoverApp.Market memory m = _market();
    vm.startPrank(underwriter);
    usdg.mint(underwriter, RESERVE);
    usdg.approve(address(aqua), type(uint256).max);
    address[] memory tokens = new address[](1);
    tokens[0] = address(usdg);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = RESERVE;
    hash = aqua.ship(address(cover), abi.encode(m), tokens, amounts);
    cover.registerMarket(m);
    vm.stopPrank();
  }

  function test_full_flow_depeg_pays_out() public {
    bytes32 hash = _ship();

    (uint256 backing, uint256 covered, uint256 util) = cover.solvency(hash);
    assertEq(backing, RESERVE);
    assertEq(covered, 0);
    assertEq(util, 0);

    uint256 coverNotional = 100_000e18;
    uint256 premium = cover.quotePremiumFor(hash, coverNotional, 30 days);
    assertGt(premium, 0, "curve premium > 0");

    vm.startPrank(buyer);
    usdg.mint(buyer, premium);
    usdg.approve(address(cover), premium);
    uint256 policyId = cover.buyPolicy(hash, coverNotional, 30 days);
    vm.stopPrank();

    assertEq(note.balanceOf(buyer, policyId), 1, "buyer holds cover note");
    (backing, covered,) = cover.solvency(hash);
    assertEq(backing, RESERVE + premium, "reserve grew by premium");
    assertEq(covered, coverNotional);

    vm.prank(buyer);
    vm.expectRevert();
    cover.claim(policyId); // not depegged yet

    oracle.set(0.9e8);
    uint256 before = usdg.balanceOf(buyer);
    vm.prank(buyer);
    uint256 payout = cover.claim(policyId);

    assertEq(payout, coverNotional);
    assertEq(usdg.balanceOf(buyer), before + coverNotional, "paid in USDG");
    assertEq(note.balanceOf(buyer, policyId), 0, "note burned on claim");
    (, covered,) = cover.solvency(hash);
    assertEq(covered, 0);
  }

  function test_premium_rises_with_utilization() public {
    bytes32 hash = _ship();
    uint256 pLow = cover.quotePremium(hash, 10_000e18); // ~1.25% util
    // fill the book to raise utilization, then quote again
    vm.startPrank(buyer);
    usdg.mint(buyer, 1_000_000e18);
    usdg.approve(address(cover), type(uint256).max);
    cover.buyPolicy(hash, 500_000e18, 30 days); // ~62.5% util
    vm.stopPrank();
    uint256 pHigh = cover.quotePremium(hash, 10_000e18);
    assertGt(pHigh, pLow, "premium rate rises with utilization");
  }

  function test_solvency_floor_blocks_oversell() public {
    bytes32 hash = _ship();
    vm.startPrank(buyer);
    usdg.mint(buyer, 200_000e18);
    usdg.approve(address(cover), type(uint256).max);
    vm.expectRevert();
    cover.buyPolicy(hash, 900_000e18, 30 days); // > 800k capacity
    vm.stopPrank();
  }

  function test_transferred_note_claims_to_fresh_wallet() public {
    bytes32 hash = _ship();
    uint256 coverNotional = 50_000e18;
    vm.startPrank(buyer);
    usdg.mint(buyer, cover.quotePremium(hash, coverNotional));
    usdg.approve(address(cover), type(uint256).max);
    uint256 policyId = cover.buyPolicy(hash, coverNotional, 30 days);
    note.transfer(bob, policyId, 1); // assign the policy to a fresh wallet
    vm.stopPrank();

    oracle.set(0.85e8);
    vm.prank(bob);
    cover.claim(policyId);
    assertEq(usdg.balanceOf(bob), coverNotional, "fresh wallet received payout");
    assertEq(note.balanceOf(bob, policyId), 0);
  }
}
