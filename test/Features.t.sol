// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {CoverApp} from "../src/CoverApp.sol";
import {CoverNote} from "../src/CoverNote.sol";
import {CoverRouter} from "../src/CoverRouter.sol";
import {SolventBook} from "../src/SolventBook.sol";
import {YieldReserve} from "../src/YieldReserve.sol";
import {IReserveHook} from "../src/interfaces/IReserveHook.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockVault} from "../src/mocks/MockVault.sol";

contract FeaturesTest is Test {
  Aqua aqua;
  CoverApp cover;
  CoverNote note;
  CoverRouter router;
  MockERC20 usdg;
  MockOracle oracle;

  address uwA = makeAddr("uwA");
  address uwB = makeAddr("uwB");
  address buyer = makeAddr("buyer");

  uint256 constant PEG = 1e8;

  function setUp() public {
    aqua = new Aqua();
    cover = new CoverApp(IAqua(address(aqua)), address(this));
    note = new CoverNote(address(cover));
    cover.initialize(note, SolventBook(address(0)));
    router = new CoverRouter(cover);
    usdg = new MockERC20("Global Dollar", "USDG");
    oracle = new MockOracle(8, PEG);
  }

  function _market(address uw, uint256 startRate, uint256 salt) internal view returns (CoverApp.Market memory m) {
    m = CoverApp.Market({
      underwriter: uw,
      asset: address(usdg),
      oracle: address(oracle),
      pegPrice: PEG,
      depegBps: 300,
      maxUtilBps: 8000,
      oracleTimeout: 1 hours,
      startRateWad: startRate,
      endRateWad: 0.1e18,
      convexityWad: 1e18,
      trigger: address(0),
      salt: bytes32(salt)
    });
  }

  function _ship(address uw, CoverApp.Market memory m, uint256 reserve) internal returns (bytes32 hash) {
    vm.startPrank(uw);
    usdg.mint(uw, reserve);
    usdg.approve(address(aqua), type(uint256).max);
    address[] memory tokens = new address[](1);
    tokens[0] = address(usdg);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = reserve;
    hash = aqua.ship(address(cover), abi.encode(m), tokens, amounts);
    cover.registerMarket(m);
    vm.stopPrank();
  }

  // ── Competitive order book: route cover across two underwriters atomically ──
  function test_router_multi_maker_route() public {
    bytes32 hA = _ship(uwA, _market(uwA, 0.01e18, 1), 500_000e18); // cheaper start
    bytes32 hB = _ship(uwB, _market(uwB, 0.02e18, 2), 500_000e18); // pricier start

    CoverRouter.Leg[] memory legs = new CoverRouter.Leg[](2);
    legs[0] = CoverRouter.Leg({strategyHash: hA, coverNotional: 100_000e18});
    legs[1] = CoverRouter.Leg({strategyHash: hB, coverNotional: 100_000e18});

    (uint256 totalCover, uint256 totalPremium) = router.quoteRoute(legs);
    assertEq(totalCover, 200_000e18);
    assertGt(totalPremium, 0);

    vm.startPrank(buyer);
    usdg.mint(buyer, totalPremium * 2);
    usdg.approve(address(router), type(uint256).max);
    (uint256[] memory ids, uint256 spent) =
      router.buyRoute(legs, address(usdg), totalPremium * 2, 30 days, buyer, block.timestamp + 1 hours);
    vm.stopPrank();

    assertEq(ids.length, 2);
    assertEq(note.balanceOf(buyer, ids[0]), 1);
    assertEq(note.balanceOf(buyer, ids[1]), 1);
    assertLe(spent, totalPremium * 2);
    assertEq(cover.outstanding(hA), 100_000e18);
    assertEq(cover.outstanding(hB), 100_000e18);
  }

  // ── Aggregate (cross-market) solvency floor from the attestor-fed SolventBook ──
  function test_aggregate_solvency_floor() public {
    bytes32 hash = _ship(uwA, _market(uwA, 0.01e18, 9), 500_000e18);
    SolventBook book = new SolventBook(address(this));
    cover.setSolventBook(book);

    vm.startPrank(buyer);
    usdg.mint(buyer, 100_000e18);
    usdg.approve(address(cover), type(uint256).max);

    // No fresh attestation => headroom 0 => aggregate floor blocks the buy
    vm.expectRevert();
    cover.buyPolicy(hash, 50_000e18, 30 days);
    vm.stopPrank();

    // Attestor publishes ample headroom => buy succeeds
    book.attest(uwA, address(usdg), 500_000e18, 0);
    vm.prank(buyer);
    cover.buyPolicy(hash, 50_000e18, 30 days);
    assertEq(cover.outstanding(hash), 50_000e18);
  }

  // ── Yield-bearing reserve: capital earns yield AND backs cover; JIT payout on claim ──
  function test_yield_reserve_backs_and_pays() public {
    MockVault vault = new MockVault(IERC20(address(usdg)));
    YieldReserve reserve = new YieldReserve(uwA, address(cover), IERC20(address(usdg)), IERC4626(address(vault)));

    uint256 RESERVE = 1_000_000e18;
    CoverApp.Market memory m = _market(address(reserve), 0.01e18, 7); // maker = the YieldReserve
    bytes32 hash = keccak256(abi.encode(m));

    // underwriter funds the reserve into the yield vault
    vm.startPrank(uwA);
    usdg.mint(uwA, RESERVE);
    usdg.approve(address(reserve), RESERVE);
    reserve.deposit(RESERVE); // now sits in the vault earning yield
    reserve.approveAqua(address(aqua)); // Aqua may pull from the reserve

    // ship + register + set the reserve hook, all AS the reserve (via execute passthrough)
    address[] memory tokens = new address[](1);
    tokens[0] = address(usdg);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = RESERVE;
    reserve.execute(address(aqua), abi.encodeCall(IAqua.ship, (address(cover), abi.encode(m), tokens, amounts)));
    reserve.execute(address(cover), abi.encodeCall(CoverApp.registerMarket, (m)));
    reserve.execute(address(cover), abi.encodeCall(CoverApp.setReserveHook, (IReserveHook(address(reserve)))));
    vm.stopPrank();

    // reserve holds ~zero liquid USDG (it's all in the vault) yet backs cover
    assertEq(usdg.balanceOf(address(reserve)), 0, "reserve idle balance ~0");
    assertEq(reserve.totalAssets(), RESERVE, "reserve fully backed via vault");

    // simulate yield: vault gains 5% underlying
    usdg.mint(address(vault), 50_000e18);
    assertGt(reserve.totalAssets(), RESERVE, "reserve earned yield");

    // buyer buys 100k cover
    uint256 coverNotional = 100_000e18;
    vm.startPrank(buyer);
    usdg.mint(buyer, cover.quotePremiumFor(hash, coverNotional, 30 days));
    usdg.approve(address(cover), type(uint256).max);
    uint256 policyId = cover.buyPolicy(hash, coverNotional, 30 days);
    vm.stopPrank();

    // depeg -> claim; reserve JIT-withdraws from the vault to satisfy the pull
    oracle.set(0.9e8);
    vm.prank(buyer);
    uint256 payout = cover.claim(policyId);
    assertEq(payout, coverNotional);
    assertEq(usdg.balanceOf(buyer), coverNotional, "buyer paid from yield reserve");
  }
}
