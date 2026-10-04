// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoverApp} from "../src/CoverApp.sol";
import {CoverNote} from "../src/CoverNote.sol";
import {SolventBook} from "../src/SolventBook.sol";
import {SlippageRefundTrigger, ISlippageSource} from "../src/triggers/SlippageRefundTrigger.sol";
import {BookSolvencyTrigger} from "../src/triggers/BookSolvencyTrigger.sol";
import {EventMarket} from "../src/futarchy/EventMarket.sol";
import {FutarchyPricer} from "../src/futarchy/FutarchyPricer.sol";
import {CrossChainCoverGateway, IMessenger} from "../src/crosschain/CrossChainCoverGateway.sol";
import {HedgeExecutor, IHedgeVenue} from "../src/hedge/HedgeExecutor.sol";
import {VerifiedMarketRegistry} from "../src/registry/VerifiedMarketRegistry.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockSlippageSource} from "../src/mocks/MockSlippageSource.sol";
import {MockMessenger} from "../src/mocks/MockMessenger.sol";
import {MockHedgeVenue} from "../src/mocks/MockHedgeVenue.sol";

contract VariationsTest is Test {
  Aqua aqua;
  CoverApp cover;
  CoverNote note;
  MockERC20 usdg;
  MockOracle oracle;

  address uw = makeAddr("uw");
  address uw2 = makeAddr("uw2");
  address buyer = makeAddr("buyer");
  uint256 constant PEG = 1e8;

  function setUp() public {
    aqua = new Aqua();
    cover = new CoverApp(IAqua(address(aqua)), address(this));
    note = new CoverNote(address(cover));
    cover.initialize(note, SolventBook(address(0)));
    usdg = new MockERC20("Global Dollar", "USDG");
    oracle = new MockOracle(8, PEG);
  }

  function _ship(address underwriter, address trigger, uint256 salt, uint256 reserve) internal returns (bytes32 hash) {
    CoverApp.Market memory m = CoverApp.Market({
      underwriter: underwriter,
      asset: address(usdg),
      oracle: address(oracle),
      pegPrice: PEG,
      depegBps: 300,
      maxUtilBps: 8000,
      oracleTimeout: 1 hours,
      startRateWad: 0.01e18,
      endRateWad: 0.10e18,
      convexityWad: 1e18,
      trigger: trigger,
      salt: bytes32(salt)
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

  function _buy(bytes32 hash, uint256 coverNotional) internal returns (uint256 policyId) {
    vm.startPrank(buyer);
    usdg.mint(buyer, cover.quotePremium(hash, coverNotional));
    usdg.approve(address(cover), type(uint256).max);
    policyId = cover.buyPolicy(hash, coverNotional, 30 days);
    vm.stopPrank();
  }

  // 1 ── MEV / slippage-refund cover ────────────────────────────────────────
  function test_slippage_refund_cover() public {
    MockSlippageSource src = new MockSlippageSource();
    SlippageRefundTrigger trig = new SlippageRefundTrigger(ISlippageSource(address(src)));
    bytes32 hash = _ship(uw, address(trig), 1, 1_000_000e18);
    trig.configure(hash, 100); // refund if slippage > 1%

    uint256 policyId = _buy(hash, 100_000e18);
    src.set(hash, policyId, 500); // 5% realized slippage
    vm.prank(buyer);
    uint256 payout = cover.claim(policyId);
    assertEq(payout, 5_000e18, "5% slippage -> 5% refund");
  }

  // 2 ── Solvency insurance for Aqua books (meta) ───────────────────────────
  function test_book_solvency_meta_cover() public {
    SolventBook book = new SolventBook(address(this));
    BookSolvencyTrigger trig = new BookSolvencyTrigger(book);
    bytes32 hash = _ship(uw, address(trig), 2, 1_000_000e18); // uw backs the meta-cover
    trig.configure(hash, uw2, address(usdg)); // insuring uw2's book

    uint256 policyId = _buy(hash, 100_000e18);
    // uw2's book goes under-backed: backing 800k vs outstanding 1M -> 20% shortfall
    book.attest(uw2, address(usdg), 800_000e18, 1_000_000e18);
    vm.prank(buyer);
    uint256 payout = cover.claim(policyId);
    assertEq(payout, 20_000e18, "20% shortfall -> 20% payout");
  }

  // 3 ── Futarchy-priced premiums ───────────────────────────────────────────
  function test_futarchy_priced_premium() public {
    bytes32 hash = _ship(uw, address(0), 3, 1_000_000e18);
    EventMarket mkt = new EventMarket(1_000_000e18); // starts at 50%
    FutarchyPricer pricer = new FutarchyPricer();
    pricer.configure(hash, mkt, 0.005e18); // 0.5% floor
    vm.prank(uw);
    cover.setPremiumPricer(hash, address(pricer));

    uint256 pMid = cover.quotePremium(hash, 100_000e18); // ~50% probability
    // market now prices the event more likely -> premium rises
    mkt.buyYes(1_000_000e18);
    uint256 pHigh = cover.quotePremium(hash, 100_000e18);
    assertGt(pHigh, pMid, "premium follows market-implied probability");
  }

  // 4 ── Cross-chain cover ──────────────────────────────────────────────────
  function test_cross_chain_cover() public {
    bytes32 hash = _ship(uw, address(0), 4, 1_000_000e18);
    MockMessenger messenger = new MockMessenger();
    CrossChainCoverGateway gw =
      new CrossChainCoverGateway(IMessenger(address(messenger)), cover, IERC20(address(usdg)), address(this));
    gw.setPeer(uint32(block.chainid), address(gw)); // loopback peer

    uint256 coverNotional = 100_000e18;
    usdg.mint(address(gw), cover.quotePremium(hash, coverNotional)); // premium bridged to the gateway
    vm.prank(buyer);
    gw.requestCover(uint32(block.chainid), hash, coverNotional, 30 days);

    assertEq(note.balanceOf(buyer, 0), 1, "policy minted cross-chain to buyer");
    assertEq(cover.outstanding(hash), coverNotional);
  }

  // 5 ── Auto-hedge (on-chain execution; keeper off-chain) ──────────────────
  function test_hedge_executor() public {
    MockHedgeVenue venue = new MockHedgeVenue();
    HedgeExecutor exec = new HedgeExecutor(IHedgeVenue(address(venue)), address(this));

    uint256 posId = exec.hedge(address(usdg), 500_000e18);
    assertEq(exec.openNotional(posId), 500_000e18, "hedge opened");
    venue.setPnl(12_345e18);
    int256 pnl = exec.unhedge(posId);
    assertEq(pnl, 12_345e18, "hedge closed with pnl");
    assertEq(exec.openNotional(posId), 0);

    // only keepers may hedge
    vm.prank(buyer);
    vm.expectRevert();
    exec.hedge(address(usdg), 1e18);
  }

  // 6 ── Verified-policy marketplace ────────────────────────────────────────
  function test_verified_market_registry() public {
    VerifiedMarketRegistry reg = new VerifiedMarketRegistry(address(this));
    bytes32 hash = keccak256("market");
    assertFalse(reg.isVerified(hash));

    reg.verify(hash, keccak256("kontrol-proof"));
    assertTrue(reg.isVerified(hash), "attestor verified");

    // non-attestor cannot verify
    vm.prank(buyer);
    vm.expectRevert();
    reg.verify(keccak256("other"), bytes32(0));

    reg.revoke(hash);
    assertFalse(reg.isVerified(hash), "revoked");
  }
}
