// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title Synergy SXCP Fact Verifier Interface
/// @author Synergy Network
/// @notice Narrow application boundary through which the reward gateway validates SXCP facts.
/// @dev Production deployment must bind this interface to the approved SXCP/Aegis verifier implementation.
interface ISXCPVerifier {
    /// @notice Authenticated cross-chain fact envelope consumed by the reward gateway.
    struct FactAttestation {
        bytes32 intentId;
        bytes32 umaId;
        uint256 sourceChainId;
        uint256 destinationChainId;
        bytes32 commitmentRef;
        bytes32 scopeDigest;
        uint256 replayNonce;
        uint64 expiry;
        uint64 witnessSetEpochId;
        uint64 aegisKeyVersion;
    }

    /// @notice Validates an SXCP fact attestation and its proof material.
    /// @dev Implementations must bind proof validity to every security-relevant field in `attestation`.
    /// @param attestation Fact envelope that binds chain, scope, replay, expiry, witness epoch, and key version.
    /// @param proof SXCP/Aegis verifier-specific proof bytes.
    /// @return valid True only when the attestation is valid under the configured verifier policy.
    function verifyFact(FactAttestation calldata attestation, bytes calldata proof)
        external
        view
        returns (bool valid);
}
