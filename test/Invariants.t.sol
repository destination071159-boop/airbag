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

/// @notice Drives random bounded policy buys against one market.
contract BuyHandler is Test {
  CoverApp public cover;
  MockERC20 public usdg;
  bytes32 public hash;
  uint256 public ghostBought;

  constructor(CoverApp _cover, MockERC20 _usdg, bytes32 _hash) {
    cover = _cover;
    usdg = _usdg;
    hash = _hash;
    usdg.approve(address(cover), type(uint256).max);
  }

  function buy(uint256 coverSeed) external {
    uint256 capacity = cover.capacityOf(hash);
    uint256 outstanding = cover.outstanding(hash);
    if (capacity <= outstanding) return;
    uint256 remaining = capacity - outstanding;
    if (remaining < 1e18) return;
    uint256 amount = bound(coverSeed, 1e18, remaining);

    uint256 premium = cover.quotePremium(hash, amount);
    usdg.mint(address(this), premium);
    cover.buyPolicy(hash, amount, 30 days);
    ghostBought += amount;
  }
}

/// @notice Solvency invariants: the fund can never oversell cover, and accounting is conserved.
contract InvariantsTest is Test {
  Aqua aqua;
  CoverApp cover;
  CoverNote note;
  MockERC20 usdg;
  MockOracle oracle;
  BuyHandler handler;
  bytes32 hash;

  address underwriter = makeAddr("underwriter");

  function setUp() public {
    aqua = new Aqua();
    cover = new CoverApp(IAqua(address(aqua)), address(this));
    note = new CoverNote(address(cover));
    cover.initialize(note, SolventBook(address(0)));
    usdg = new MockERC20("Global Dollar", "USDG");
    oracle = new MockOracle(8, 1e8);

    CoverApp.Market memory m = CoverApp.Market({
      underwriter: underwriter,
      asset: address(usdg),
      oracle: address(oracle),
      pegPrice: 1e8,
      depegBps: 300,
      maxUtilBps: 8000,
      oracleTimeout: 1 hours,
      startRateWad: 0.01e18,
      endRateWad: 0.1e18,
      convexityWad: 1e18,
      trigger: address(0),
      salt: bytes32(uint256(1))
    });
    vm.startPrank(underwriter);
    usdg.mint(underwriter, 1_000_000e18);
    usdg.approve(address(aqua), type(uint256).max);
    address[] memory tokens = new address[](1);
    tokens[0] = address(usdg);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1_000_000e18;
    hash = aqua.ship(address(cover), abi.encode(m), tokens, amounts);
    cover.registerMarket(m);
    vm.stopPrank();

    handler = new BuyHandler(cover, usdg, hash);
    targetContract(address(handler));
  }

  /// @dev The fund can never oversell: outstanding cover never exceeds capacity (backing * maxUtil).
  function invariant_outstanding_within_capacity() public view {
    assertLe(cover.outstanding(hash), cover.capacityOf(hash));
  }

  /// @dev Accounting conservation: outstanding equals the total cover bought (no claims in this run).
  function invariant_outstanding_conserved() public view {
    assertEq(cover.outstanding(hash), handler.ghostBought());
  }
}
