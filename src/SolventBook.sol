// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title SolventBook
/// @notice The one number Aqua can't compute on-chain: each underwriter's TOTAL outstanding cover
///         across all markets vs their live backing (min(walletBalance, allowance(maker, aqua))).
///         An off-chain attestor re-reads live backing (wallets can drain with no Aqua event) and
///         publishes it here; the CoverApp reads it as an aggregate solvency floor so a single
///         reserve can never oversell cover across markets. This is the on-chain-provable
///         "reserve >= outstanding cover" meter that legacy DeFi insurers cannot offer.
contract SolventBook {
  struct Book {
    uint256 backing; // min(wallet balance, aqua allowance) of the underwriter, per asset
    uint256 outstanding; // total covered notional the underwriter backs across all markets
    uint64 updatedAt;
  }

  address public owner;
  mapping(address attestor => bool) public isAttestor;
  // underwriter => asset => book
  mapping(address underwriter => mapping(address asset => Book)) public books;

  uint256 public maxStaleness = 1 hours;

  event AttestorSet(address indexed attestor, bool approved);
  event BookUpdated(address indexed underwriter, address indexed asset, uint256 backing, uint256 outstanding);
  event OwnershipTransferred(address indexed from, address indexed to);
  event MaxStalenessSet(uint256 seconds_);

  error NotOwner();
  error NotAttestor();

  modifier onlyOwner() {
    if (msg.sender != owner) revert NotOwner();
    _;
  }

  constructor(address _owner) {
    owner = _owner;
    isAttestor[_owner] = true;
    emit OwnershipTransferred(address(0), _owner);
    emit AttestorSet(_owner, true);
  }

  function setAttestor(address attestor, bool approved) external onlyOwner {
    isAttestor[attestor] = approved;
    emit AttestorSet(attestor, approved);
  }

  function setMaxStaleness(uint256 seconds_) external onlyOwner {
    maxStaleness = seconds_;
    emit MaxStalenessSet(seconds_);
  }

  function transferOwnership(address to) external onlyOwner {
    emit OwnershipTransferred(owner, to);
    owner = to;
  }

  /// @notice Attestor publishes the underwriter's live backing and aggregate outstanding cover.
  function attest(address underwriter, address asset, uint256 backing, uint256 outstanding) external {
    if (!isAttestor[msg.sender]) revert NotAttestor();
    books[underwriter][asset] = Book({backing: backing, outstanding: outstanding, updatedAt: uint64(block.timestamp)});
    emit BookUpdated(underwriter, asset, backing, outstanding);
  }

  /// @return solvent True if backing >= outstanding and the attestation is fresh.
  function isSolvent(address underwriter, address asset) external view returns (bool solvent) {
    Book storage b = books[underwriter][asset];
    if (b.updatedAt == 0 || block.timestamp - b.updatedAt > maxStaleness) return false;
    return b.backing >= b.outstanding;
  }

  /// @return utilizationBps outstanding / backing in bps (0 if no backing or no fresh attestation).
  function utilizationBps(address underwriter, address asset) external view returns (uint256) {
    Book storage b = books[underwriter][asset];
    if (b.backing == 0 || b.updatedAt == 0 || block.timestamp - b.updatedAt > maxStaleness) return 0;
    return b.outstanding * 10_000 / b.backing;
  }

  /// @notice Headroom (backing - outstanding), 0 if under-backed or stale.
  function headroom(address underwriter, address asset) external view returns (uint256) {
    Book storage b = books[underwriter][asset];
    if (b.updatedAt == 0 || block.timestamp - b.updatedAt > maxStaleness || b.outstanding > b.backing) return 0;
    return b.backing - b.outstanding;
  }
}
