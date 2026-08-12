// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title Synergy Staking Attestation Verifier Interface
/// @notice Narrow Ethereum boundary for threshold-authenticated Base staking facts.
/// @dev Every field is EIP-712 signed. The gateway independently compares the
///      economic fields with the commitment it is about to apply.
interface IStakingAttestationVerifier {
    /// @notice Lifecycle operation authenticated from the Base staking event.
    enum RewardAction {
        REGISTER,
        ISSUE,
        CANCEL
    }

    /// @notice Canonical EIP-712 attestation for one finalized Base staking event.
    /// @dev `sourceEventId` is derived from sourceChainId, sourceStakingContract,
    ///      sourceTxHash, and sourceLogIndex. `amount` is represented by the
    ///      explicit principal/reward fields to avoid an ambiguous action-specific
    ///      interpretation.
    struct StakingAttestation {
        uint256 sourceChainId;
        uint256 destinationChainId;
        address sourceStakingContract;
        bytes32 sourceTxHash;
        uint64 sourceBlockNumber;
        bytes32 sourceBlockHash;
        uint64 sourceLogIndex;
        address staker;
        address beneficiary;
        uint8 stakeSourceType;
        address sourceAsset;
        uint256 sourceTokenId;
        bytes32 allocationId;
        uint256 sourcePositionId;
        uint256 principalNwei;
        uint256 rewardNwei;
        uint16 rewardBps;
        uint64 startedAt;
        uint64 maturesAt;
        bytes32 rewardId;
        RewardAction action;
        uint8 cancellationReason;
        uint64 attestationEpoch;
        uint64 expiry;
    }

    /// @notice Validates threshold signatures for an exact finalized Base fact.
    function verifyAttestation(StakingAttestation calldata attestation, bytes[] calldata signatures)
        external
        view
        returns (bool valid);

    /// @notice Deterministically identifies the immutable source event.
    function sourceEventId(StakingAttestation calldata attestation) external pure returns (bytes32);

    /// @notice Returns the EIP-712 digest attestors must sign.
    function attestationDigest(StakingAttestation calldata attestation)
        external
        view
        returns (bytes32);
}
