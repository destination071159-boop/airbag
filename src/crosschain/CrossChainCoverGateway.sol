// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoverApp} from "../CoverApp.sol";

/// @notice Generic cross-chain messenger (abstracts LayerZero / CCIP / Hyperlane).
interface IMessenger {
  function send(uint32 dstChainId, address target, bytes calldata payload) external;
}

interface IMessageReceiver {
  function onMessage(uint32 srcChainId, bytes calldata payload) external;
}

/// @title CrossChainCoverGateway
/// @notice Buy cover on a chain where the underwriter's reserve lives, from another chain: a buyer
///         requests on the origin gateway, a message is relayed, and the destination gateway mints
///         the policy to the buyer against the local CoverApp. One underwriter wallet can thus back
///         cover for buyers on many chains.
/// @dev The bridge is an `IMessenger` (mock in tests; LayerZero/CCIP/Hyperlane in production). Premium
///      is assumed bridged/pre-funded to the destination gateway (abstracted here).
contract CrossChainCoverGateway is IMessageReceiver {
  using SafeERC20 for IERC20;

  IMessenger public immutable messenger;
  CoverApp public immutable cover;
  IERC20 public immutable premiumAsset;
  address public immutable owner;

  mapping(uint32 chainId => address gateway) public peer; // trusted peer gateway per chain

  event CoverRequested(uint32 indexed dstChainId, address indexed buyer, bytes32 strategyHash, uint256 coverNotional);
  event CoverFulfilled(uint32 indexed srcChainId, address indexed buyer, uint256 policyId);

  error NotOwner();
  error NotMessenger();
  error UntrustedPeer();

  constructor(IMessenger _messenger, CoverApp _cover, IERC20 _premiumAsset, address _owner) {
    messenger = _messenger;
    cover = _cover;
    premiumAsset = _premiumAsset;
    owner = _owner;
  }

  function setPeer(uint32 chainId, address gateway) external {
    if (msg.sender != owner) revert NotOwner();
    peer[chainId] = gateway;
  }

  /// @notice Origin chain: request cover that will be minted on `dstChainId`.
  function requestCover(uint32 dstChainId, bytes32 strategyHash, uint256 coverNotional, uint64 duration) external {
    address target = peer[dstChainId];
    if (target == address(0)) revert UntrustedPeer();
    bytes memory payload = abi.encode(msg.sender, strategyHash, coverNotional, duration);
    messenger.send(dstChainId, target, payload);
    emit CoverRequested(dstChainId, msg.sender, strategyHash, coverNotional);
  }

  /// @notice Destination chain: relayed message mints the policy to the original buyer.
  function onMessage(uint32 srcChainId, bytes calldata payload) external {
    if (msg.sender != address(messenger)) revert NotMessenger();
    (address buyer, bytes32 strategyHash, uint256 coverNotional, uint64 duration) =
      abi.decode(payload, (address, bytes32, uint256, uint64));

    uint256 premium = cover.quotePremium(strategyHash, coverNotional);
    premiumAsset.forceApprove(address(cover), premium); // gateway is pre-funded with bridged premium
    uint256 policyId = cover.buyPolicyFor(strategyHash, coverNotional, duration, buyer);
    emit CoverFulfilled(srcChainId, buyer, policyId);
  }
}
