// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title VerifiedMarketRegistry
/// @notice A "verified-policy marketplace" layer: an attestor records that a market's program carries
///         an off-chain proof (e.g. a Kontrol/KEVM proof that payout <= reserve and the trigger logic
///         is sound) and/or a solvency guarantee. Front-ends and routers can require `isVerified`
///         before quoting/selling, giving takers trust-minimized cover. The proof is produced
///         off-chain; this registry records the attestation and the proof hash on-chain.
contract VerifiedMarketRegistry {
  struct Attestation {
    bool verified;
    bytes32 proofHash; // hash/commitment of the off-chain proof artifact
    uint64 attestedAt;
    address attestor;
  }

  address public owner;
  mapping(address attestor => bool) public isAttestor;
  mapping(bytes32 marketHash => Attestation) public attestations;

  event AttestorSet(address indexed attestor, bool allowed);
  event MarketVerified(bytes32 indexed marketHash, bytes32 proofHash, address indexed attestor);
  event MarketRevoked(bytes32 indexed marketHash);

  error NotOwner();
  error NotAttestor();

  constructor(address _owner) {
    owner = _owner;
    isAttestor[_owner] = true;
  }

  function setAttestor(address attestor, bool allowed) external {
    if (msg.sender != owner) revert NotOwner();
    isAttestor[attestor] = allowed;
    emit AttestorSet(attestor, allowed);
  }

  function verify(bytes32 marketHash, bytes32 proofHash) external {
    if (!isAttestor[msg.sender]) revert NotAttestor();
    attestations[marketHash] =
      Attestation({verified: true, proofHash: proofHash, attestedAt: uint64(block.timestamp), attestor: msg.sender});
    emit MarketVerified(marketHash, proofHash, msg.sender);
  }

  function revoke(bytes32 marketHash) external {
    if (!isAttestor[msg.sender]) revert NotAttestor();
    attestations[marketHash].verified = false;
    emit MarketRevoked(marketHash);
  }

  function isVerified(bytes32 marketHash) external view returns (bool) {
    return attestations[marketHash].verified;
  }
}
