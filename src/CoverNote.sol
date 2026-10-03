// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title CoverNote
/// @notice Minimal ERC-6909 policy token. Each policy is token id = policyId, minted 1:1 to the
///         buyer. Holding the note = owning the policy; whoever holds it can claim. Transferable, so
///         cover is assignable and tradable (this is the feature that stands in for the ZK-private
///         claim path). Only the CoverApp may mint/burn.
contract CoverNote {
  string public constant name = "Airbag Cover Note";
  string public constant symbol = "COVER";

  address public immutable coverApp;

  // ERC-6909 storage
  mapping(address owner => mapping(uint256 id => uint256)) public balanceOf;
  mapping(address owner => mapping(address spender => mapping(uint256 id => uint256))) public allowance;
  mapping(address owner => mapping(address operator => bool)) public isOperator;
  /// @notice Current holder of each policy note (policies are minted with amount 1), so a keeper can
  ///         push a payout to whoever holds the cover right now — no claim transaction needed.
  mapping(uint256 id => address) public holderOf;

  event Transfer(address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount);
  event OperatorSet(address indexed owner, address indexed operator, bool approved);
  event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);

  error NotCoverApp();
  error InsufficientBalance();
  error InsufficientPermission();

  modifier onlyCoverApp() {
    if (msg.sender != coverApp) revert NotCoverApp();
    _;
  }

  constructor(address _coverApp) {
    coverApp = _coverApp;
  }

  function transfer(address to, uint256 id, uint256 amount) public returns (bool) {
    _moveBalance(msg.sender, to, id, amount);
    emit Transfer(msg.sender, msg.sender, to, id, amount);
    return true;
  }

  function transferFrom(address from, address to, uint256 id, uint256 amount) public returns (bool) {
    if (msg.sender != from && !isOperator[from][msg.sender]) {
      uint256 allowed = allowance[from][msg.sender][id];
      if (allowed != type(uint256).max) {
        if (allowed < amount) revert InsufficientPermission();
        allowance[from][msg.sender][id] = allowed - amount;
      }
    }
    _moveBalance(from, to, id, amount);
    emit Transfer(msg.sender, from, to, id, amount);
    return true;
  }

  function approve(address spender, uint256 id, uint256 amount) public returns (bool) {
    allowance[msg.sender][spender][id] = amount;
    emit Approval(msg.sender, spender, id, amount);
    return true;
  }

  function setOperator(address operator, bool approved) public returns (bool) {
    isOperator[msg.sender][operator] = approved;
    emit OperatorSet(msg.sender, operator, approved);
    return true;
  }

  function mint(address to, uint256 id, uint256 amount) external onlyCoverApp {
    balanceOf[to][id] += amount;
    holderOf[id] = to;
    emit Transfer(msg.sender, address(0), to, id, amount);
  }

  function burn(address from, uint256 id, uint256 amount) external onlyCoverApp {
    if (balanceOf[from][id] < amount) revert InsufficientBalance();
    unchecked {
      balanceOf[from][id] -= amount;
    }
    if (balanceOf[from][id] == 0) delete holderOf[id];
    emit Transfer(msg.sender, from, address(0), id, amount);
  }

  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return interfaceId == 0x0f632fb3 // ERC-6909
      || interfaceId == 0x01ffc9a7; // ERC-165
  }

  function _moveBalance(address from, address to, uint256 id, uint256 amount) internal {
    if (balanceOf[from][id] < amount) revert InsufficientBalance();
    unchecked {
      balanceOf[from][id] -= amount;
    }
    balanceOf[to][id] += amount;
    if (amount > 0) holderOf[id] = to;
  }
}
