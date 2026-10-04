// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoverApp} from "../src/CoverApp.sol";
import {CoverNote} from "../src/CoverNote.sol";
import {SolventBook} from "../src/SolventBook.sol";
import {TranchedReserve} from "../src/TranchedReserve.sol";
import {PriceGapTrigger} from "../src/triggers/PriceGapTrigger.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract ProductsTest is Test {
  Aqua aqua;
  CoverApp cover;
  CoverNote note;
  MockERC20 usdg;
  MockOracle oracle;

  address uw = makeAddr("uw");
  address buyer = makeAddr("buyer");
  address senior = makeAddr("senior");
  address junior = makeAddr("junior");

  uint256 constant PEG = 1e8;

  function setUp() public {
    aqua = new Aqua();
    cover = new CoverApp(IAqua(address(aqua)), address(this));
    note = new CoverNote(address(cover));
    cover.initialize(note, SolventBook(address(0)));
    usdg = new MockERC20("Global Dollar", "USDG");
    oracle = new MockOracle(8, PEG);
  }

  function _shipMarket(address underwriter, address trigger, uint256 reserve) internal returns (bytes32 hash) {
    CoverApp.Market memory m = CoverApp.Market({
      underwriter: underwriter,
      asset: address(usdg),
      oracle: address(oracle),
      pegPrice: PEG,
      depegBps: 300,
      maxUtilBps: 8000,
      oracleTimeout: 1 hours,
      startRateWad: 0.01e18,
      endRateWad: 0.1e18,
      convexityWad: 1e18,
      trigger: trigger,
      salt: bytes32(uint256(uint160(trigger)) ^ 0xabc)
    });
    vm.startPrank(underwriter);
    usdg.mint(underwriter, reserve);
    usdg.approve(address(aqua), type(uint256).max);
    address[] memory tokens = new address[](1);
    tokens[0] = address(usdg);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = reserve;
    hash = aqua.ship(address(cover), abi.encode(m), tokens, amounts);
    cover.registerMarket(m);
    vm.stopPrank();
  }

  // ── RWA / gap-down cover via a pluggable trigger, with proportional payout ──
  function test_pricegap_trigger_pays_proportional() public {
    PriceGapTrigger gap = new PriceGapTrigger();
    bytes32 hash = _shipMarket(uw, address(gap), 1_000_000e18);
    gap.configure(hash, address(oracle), PEG, 1 hours); // strike = $1.00

    uint256 coverNotional = 100_000e18;
    vm.startPrank(buyer);
    usdg.mint(buyer, cover.quotePremiumFor(hash, coverNotional, 30 days));
    usdg.approve(address(cover), type(uint256).max);
    uint256 policyId = cover.buyPolicy(hash, coverNotional, 30 days);
    vm.stopPrank();

    // asset drops 10% below strike -> 1000 bps -> 10% of notional
    oracle.set(0.9e8);
    vm.prank(buyer);
    uint256 payout = cover.claim(policyId);
    assertEq(payout, 10_000e18, "proportional 10% payout");
    assertEq(usdg.balanceOf(buyer), 10_000e18);
  }

  // ── Reinsurance tranches: junior takes first loss, earns more premium ──
  function test_tranched_reserve_waterfall() public {
    TranchedReserve tr = new TranchedReserve(IERC20(address(usdg)), address(this), 7000); // junior 70% of profit

    vm.startPrank(senior);
    usdg.mint(senior, 800_000e18);
    usdg.approve(address(tr), type(uint256).max);
    tr.depositSenior(800_000e18);
    vm.stopPrank();

    vm.startPrank(junior);
    usdg.mint(junior, 200_000e18);
    usdg.approve(address(tr), type(uint256).max);
    tr.depositJunior(200_000e18);
    vm.stopPrank();

    (uint256 jVal, uint256 sVal) = tr.trancheValues();
    assertEq(jVal, 200_000e18, "junior principal");
    assertEq(sVal, 800_000e18, "senior principal");

    // a 100k payout (Aqua pull) -> junior absorbs first
    deal(address(usdg), address(tr), 900_000e18);
    (jVal, sVal) = tr.trancheValues();
    assertEq(jVal, 100_000e18, "junior took the loss");
    assertEq(sVal, 800_000e18, "senior protected");

    // 60k premium profit -> junior earns 70%
    deal(address(usdg), address(tr), 1_060_000e18); // principals 1M, profit 60k
    (jVal, sVal) = tr.trancheValues();
    assertEq(jVal, 200_000e18 + 42_000e18, "junior +70% of profit");
    assertEq(sVal, 800_000e18 + 18_000e18, "senior +30% of profit");
  }
}
