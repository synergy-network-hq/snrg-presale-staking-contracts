// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStakingAttestationVerifier} from "../interfaces/IStakingAttestationVerifier.sol";
import {IRewardVoucherLedger} from "../interfaces/IRewardVoucherLedger.sol";
import {RewardTypes} from "../common/RewardTypes.sol";

/// @title Synergy Base Reward Gateway
/// @notice Ethereum gateway for threshold-attested, finalized Base staking lifecycle events.
/// @dev The gateway never receives a general mint capability. It receives only the
///      ledger roles necessary to register, issue, and cancel the exact commitment
///      whose EIP-712 attestation it has validated. Any account may submit a valid
///      relay transaction; the relayer has no special on-chain authority.
contract SXCPRewardGateway is ReentrancyGuard {
    uint256 public constant BASE_CHAIN_ID = 8_453;
    uint256 public constant ETHEREUM_CHAIN_ID = 1;
    uint256 public constant MAX_SIGNATURES = 32;

    IStakingAttestationVerifier public immutable attestationVerifier;
    IRewardVoucherLedger public immutable rewardVoucherLedger;
    address public immutable baseStakingContract;

    /// @notice Source-event IDs permanently consumed by the gateway.
    mapping(bytes32 sourceEventId => bool consumed) public consumedSourceEvents;

    error ZeroAddress();
    error NotContract(address target);
    error EtherNotAccepted();
    error InvalidSource();
    error InvalidDestination();
    error ExpiredAttestation();
    error InvalidAction();
    error InvalidCancellationReason();
    error AttestationCommitmentMismatch();
    error InvalidAttestation();
    error SourceEventAlreadyConsumed(bytes32 sourceEventId);

    event BaseRewardGatewayConfigured(
        address indexed verifier, address indexed rewardVoucherLedger, address indexed baseStakingContract
    );
    event BaseStakingAttestationConsumed(
        bytes32 indexed sourceEventId,
        bytes32 indexed rewardId,
        IStakingAttestationVerifier.RewardAction action
    );

    constructor(address verifier, address rewardLedger, address baseStaking) payable {
        if (msg.value != 0) revert EtherNotAccepted();
        if (verifier == address(0) || rewardLedger == address(0) || baseStaking == address(0)) {
            revert ZeroAddress();
        }
        if (verifier.code.length == 0) revert NotContract(verifier);
        if (rewardLedger.code.length == 0) revert NotContract(rewardLedger);

        attestationVerifier = IStakingAttestationVerifier(verifier);
        rewardVoucherLedger = IRewardVoucherLedger(rewardLedger);
        baseStakingContract = baseStaking;
        emit BaseRewardGatewayConfigured(verifier, rewardLedger, baseStaking);
    }

    /// @notice Registers a pending Base reward after threshold validation of RewardCommitmentOpened.
    function registerPendingReward(
        RewardTypes.RewardCommitment calldata commitment,
        IStakingAttestationVerifier.StakingAttestation calldata attestation,
        bytes[] calldata signatures
    ) external nonReentrant {
        _verifyAndConsume(commitment, attestation, signatures, IStakingAttestationVerifier.RewardAction.REGISTER, 0);
        rewardVoucherLedger.registerPendingReward(commitment);
    }

    /// @notice Issues a matured Base reward voucher after threshold validation of RewardSettlementAuthorized.
    function issueRewardVoucher(
        RewardTypes.RewardCommitment calldata commitment,
        IStakingAttestationVerifier.StakingAttestation calldata attestation,
        bytes[] calldata signatures
    ) external nonReentrant returns (uint256 tokenId) {
        _verifyAndConsume(commitment, attestation, signatures, IStakingAttestationVerifier.RewardAction.ISSUE, 0);
        return rewardVoucherLedger.issueRewardVoucher(commitment);
    }

    /// @notice Cancels a Base reward after threshold validation of RewardCommitmentCancelled.
    function cancelPendingReward(
        RewardTypes.RewardCommitment calldata commitment,
        RewardTypes.CancellationReason reason,
        IStakingAttestationVerifier.StakingAttestation calldata attestation,
        bytes[] calldata signatures
    ) external nonReentrant {
        if (reason == RewardTypes.CancellationReason.NONE) revert InvalidCancellationReason();
        _verifyAndConsume(
            commitment,
            attestation,
            signatures,
            IStakingAttestationVerifier.RewardAction.CANCEL,
            uint8(reason)
        );
        rewardVoucherLedger.cancelPendingReward(commitment, reason);
    }

    function sourceEventId(IStakingAttestationVerifier.StakingAttestation calldata attestation)
        external
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256(
                    "SYNERGY_STAKING_SOURCE_EVENT_V1(uint256 sourceChainId,address sourceStakingContract,bytes32 sourceTxHash,uint64 sourceLogIndex)"
                ),
                attestation.sourceChainId,
                attestation.sourceStakingContract,
                attestation.sourceTxHash,
                attestation.sourceLogIndex
            )
        );
    }

    function _verifyAndConsume(
        RewardTypes.RewardCommitment calldata commitment,
        IStakingAttestationVerifier.StakingAttestation calldata attestation,
        bytes[] calldata signatures,
        IStakingAttestationVerifier.RewardAction expectedAction,
        uint8 expectedCancellationReason
    ) private {
        if (signatures.length == 0 || signatures.length > MAX_SIGNATURES) revert InvalidAttestation();
        if (attestation.expiry <= block.timestamp) revert ExpiredAttestation();
        if (attestation.action != expectedAction) revert InvalidAction();
        if (attestation.cancellationReason != expectedCancellationReason) revert InvalidCancellationReason();
        _requireBoundCommitment(commitment, attestation);

        bytes32 eventId = attestationVerifier.sourceEventId(attestation);
        if (consumedSourceEvents[eventId]) revert SourceEventAlreadyConsumed(eventId);

        // Reservation is made before external verification and rolls back atomically
        // if signature validation or the ledger transition fails.
        consumedSourceEvents[eventId] = true;
        if (!attestationVerifier.verifyAttestation(attestation, signatures)) revert InvalidAttestation();
        emit BaseStakingAttestationConsumed(eventId, commitment.rewardId, expectedAction);
    }

    function _requireBoundCommitment(
        RewardTypes.RewardCommitment calldata commitment,
        IStakingAttestationVerifier.StakingAttestation calldata attestation
    ) private view {
        if (
            commitment.sourceChainId != BASE_CHAIN_ID || commitment.sourceStakingContract != baseStakingContract
                || attestation.sourceChainId != BASE_CHAIN_ID || attestation.destinationChainId != ETHEREUM_CHAIN_ID
                || attestation.sourceStakingContract != baseStakingContract
        ) revert InvalidSource();
        if (
            attestation.staker != commitment.beneficiary || attestation.beneficiary != commitment.beneficiary
                || attestation.stakeSourceType != uint8(commitment.stakeSource)
                || attestation.sourceAsset != commitment.sourceAsset
                || attestation.sourceTokenId != commitment.sourceTokenId
                || attestation.allocationId != commitment.allocationId
                || attestation.sourcePositionId != commitment.sourcePositionId
                || attestation.principalNwei != commitment.principalNwei
                || attestation.rewardNwei != commitment.rewardNwei || attestation.rewardBps != commitment.rewardBps
                || attestation.startedAt != commitment.startedAt || attestation.maturesAt != commitment.maturesAt
                || attestation.rewardId != commitment.rewardId
        ) revert AttestationCommitmentMismatch();
    }
}
