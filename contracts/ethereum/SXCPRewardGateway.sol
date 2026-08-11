// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISXCPVerifier} from "../interfaces/ISXCPVerifier.sol";
import {IRewardVoucherLedger} from "../interfaces/IRewardVoucherLedger.sol";
import {RewardTypes} from "../common/RewardTypes.sol";

/// @title Synergy SXCP Reward Gateway
/// @author Synergy Network
/// @notice Ethereum application gateway that consumes authenticated SXCP facts for Base-originating staking rewards.
/// @dev The gateway never bridges or custodies SNRG. Any caller may relay a fact, but state transitions occur only
///      after the immutable SXCP verifier accepts a Base-to-Ethereum attestation with the exact expected scope.
contract SXCPRewardGateway is ReentrancyGuard {
    uint256 private constant _BASE_CHAIN_ID = 8_453;
    uint256 private constant _ETHEREUM_CHAIN_ID = 1;

    bytes32 private constant _ACTION_REGISTER_PENDING =
        keccak256("SYNERGY_STAKING_REGISTER_PENDING_V1");
    bytes32 private constant _ACTION_ISSUE_REWARD =
        keccak256("SYNERGY_STAKING_ISSUE_REWARD_V1");
    bytes32 private constant _ACTION_CANCEL_PENDING =
        keccak256("SYNERGY_STAKING_CANCEL_PENDING_V1");

    /// @notice Immutable SXCP/Aegis fact verifier used by this gateway.
    ISXCPVerifier public immutable sxcpVerifier;

    /// @notice Immutable Ethereum reward voucher ledger called after fact verification.
    IRewardVoucherLedger public immutable rewardVoucherLedger;

    /// @notice Canonical Base staking application address whose reward facts are accepted.
    address public immutable baseStakingContract;

    /// @notice Tracks consumed SXCP attestation IDs to enforce application-level replay protection.
    mapping(bytes32 attestationId => bool consumed) public consumedAttestations;

    /// @notice Reverts when a required constructor address is zero.
    error ZeroAddress();
    /// @notice Reverts when an Ethereum-local dependency has no deployed bytecode.
    error NotContract(address target);
    /// @notice Reverts when constructor ETH is non-zero.
    error EtherNotAccepted();
    /// @notice Reverts when source chain or source staking application does not match Base staking.
    error InvalidSource();
    /// @notice Reverts when an attestation targets a chain other than Ethereum mainnet.
    error InvalidDestination();
    /// @notice Reverts when a non-zero SXCP expiry has passed.
    error ExpiredAttestation();
    /// @notice Reverts when the attested scope digest does not exactly match the requested reward action.
    error InvalidScopeDigest();
    /// @notice Reverts when the SXCP verifier rejects an attestation/proof pair.
    error InvalidSXCPProof();
    /// @notice Reverts when the same authenticated attestation is replayed.
    error AttestationAlreadyConsumed();
    /// @notice Reverts when a cancellation reason is NONE.
    error InvalidCancellationReason();

    /// @notice Emitted once when immutable gateway dependencies are configured.
    event SXCPRewardGatewayConfigured(
        address indexed verifier,
        address indexed rewardVoucherLedger,
        address indexed baseStakingContract
    );

    /// @notice Emitted after an authenticated SXCP fact is consumed exactly once.
    event SXCPRewardFactConsumed(
        bytes32 indexed attestationId,
        bytes32 indexed rewardId,
        bytes32 indexed action
    );

    /// @notice Emitted after an SXCP/Aegis fact passes verification and its replay ID is reserved.
    event SXCPAttestationVerified(bytes32 indexed attestationId, bytes32 indexed scopeDigest);

    /// @notice Deploys the immutable Base-to-Ethereum staking reward gateway.
    /// @dev verifier and rewardLedger are Ethereum-local contracts and are code-checked. baseStaking is a remote
    ///      Base address, so only non-zero validation is appropriate on Ethereum.
    /// @param verifier Approved Ethereum SXCP/Aegis fact verifier.
    /// @param rewardLedger Canonical Ethereum staking reward voucher ledger.
    /// @param baseStaking Canonical Base Synergy staking contract address.
    constructor(address verifier, address rewardLedger, address baseStaking) payable {
        if (msg.value != 0) revert EtherNotAccepted();
        if (verifier == address(0)) revert ZeroAddress();
        if (rewardLedger == address(0)) revert ZeroAddress();
        if (baseStaking == address(0)) revert ZeroAddress();
        if (verifier.code.length == 0) revert NotContract(verifier);
        if (rewardLedger.code.length == 0) revert NotContract(rewardLedger);

        sxcpVerifier = ISXCPVerifier(verifier);
        rewardVoucherLedger = IRewardVoucherLedger(rewardLedger);
        baseStakingContract = baseStaking;

        emit SXCPRewardGatewayConfigured(verifier, rewardLedger, baseStaking);
    }

    /// @notice Registers a Base-originating reward commitment as pending on Ethereum after SXCP verification.
    /// @dev Anyone may relay, but the exact source/scope and SXCP proof must verify and the attestation is single-use.
    /// @param commitment Canonical reward commitment emitted by Base staking.
    /// @param attestation SXCP fact envelope bound to the register-pending action.
    /// @param proof SXCP/Aegis verifier proof bytes.
    function registerPendingReward(
        RewardTypes.RewardCommitment calldata commitment,
        ISXCPVerifier.FactAttestation calldata attestation,
        bytes calldata proof
    ) external nonReentrant {
        _requireBaseCommitment(commitment);

        bytes32 expectedScope = keccak256(
            abi.encode(_ACTION_REGISTER_PENDING, commitment, attestation.commitmentRef)
        );
        bytes32 verifiedAttestationId = _verifyAndConsume(attestation, proof, expectedScope);

        rewardVoucherLedger.registerPendingReward(commitment);
        emit SXCPRewardFactConsumed(
            verifiedAttestationId,
            commitment.rewardId,
            _ACTION_REGISTER_PENDING
        );
    }

    /// @notice Issues the Ethereum reward NFT for a matured Base position after SXCP verification.
    /// @dev Anyone may relay; authenticated SXCP provenance and replay protection provide authorization.
    /// @param commitment Canonical reward commitment emitted by Base staking.
    /// @param attestation SXCP fact envelope bound to the issue-reward action.
    /// @param proof SXCP/Aegis verifier proof bytes.
    /// @return tokenId Issued Ethereum reward voucher token ID.
    function issueRewardVoucher(
        RewardTypes.RewardCommitment calldata commitment,
        ISXCPVerifier.FactAttestation calldata attestation,
        bytes calldata proof
    ) external nonReentrant returns (uint256 tokenId) {
        _requireBaseCommitment(commitment);

        bytes32 expectedScope = keccak256(
            abi.encode(_ACTION_ISSUE_REWARD, commitment, attestation.commitmentRef)
        );
        bytes32 verifiedAttestationId = _verifyAndConsume(attestation, proof, expectedScope);

        tokenId = rewardVoucherLedger.issueRewardVoucher(commitment);
        emit SXCPRewardFactConsumed(
            verifiedAttestationId,
            commitment.rewardId,
            _ACTION_ISSUE_REWARD
        );
        return tokenId;
    }

    /// @notice Cancels an unissued Base-originating reward after early unstake or source invalidation.
    /// @dev The cancellation reason is included in the authenticated SXCP scope and cannot be relabeled by a relayer.
    /// @param commitment Canonical reward commitment emitted by Base staking.
    /// @param reason EARLY_UNSTAKE or SOURCE_INVALIDATED.
    /// @param attestation SXCP fact envelope bound to the cancel-pending action and reason.
    /// @param proof SXCP/Aegis verifier proof bytes.
    function cancelPendingReward(
        RewardTypes.RewardCommitment calldata commitment,
        RewardTypes.CancellationReason reason,
        ISXCPVerifier.FactAttestation calldata attestation,
        bytes calldata proof
    ) external nonReentrant {
        _requireBaseCommitment(commitment);
        if (reason == RewardTypes.CancellationReason.NONE) revert InvalidCancellationReason();

        bytes32 expectedScope = keccak256(
            abi.encode(_ACTION_CANCEL_PENDING, commitment, reason, attestation.commitmentRef)
        );
        bytes32 verifiedAttestationId = _verifyAndConsume(attestation, proof, expectedScope);

        rewardVoucherLedger.cancelPendingReward(commitment, reason);
        emit SXCPRewardFactConsumed(
            verifiedAttestationId,
            commitment.rewardId,
            _ACTION_CANCEL_PENDING
        );
    }

    /// @notice Computes the canonical application replay ID for an SXCP fact envelope.
    /// @dev Uses canonical ABI encoding of every fixed attestation field.
    /// @param attestation SXCP fact envelope.
    /// @return Canonical attestation ID used by consumedAttestations.
    function attestationId(ISXCPVerifier.FactAttestation calldata attestation)
        external
        pure
        returns (bytes32)
    {
        return _attestationId(attestation);
    }

    /// @dev Verifies source/destination/scope/replay properties and calls the immutable SXCP verifier.
    function _verifyAndConsume(
        ISXCPVerifier.FactAttestation calldata attestation,
        bytes calldata proof,
        bytes32 expectedScope
    ) internal returns (bytes32 verifiedAttestationId) {
        if (attestation.sourceChainId != _BASE_CHAIN_ID) revert InvalidSource();
        if (attestation.destinationChainId != _ETHEREUM_CHAIN_ID) revert InvalidDestination();
        if (attestation.expiry != 0) {
            if (block.timestamp > attestation.expiry) revert ExpiredAttestation();
        }
        if (attestation.scopeDigest != expectedScope) revert InvalidScopeDigest();

        verifiedAttestationId = _attestationId(attestation);
        if (consumedAttestations[verifiedAttestationId]) revert AttestationAlreadyConsumed();

        // Effects before interaction. If verification fails, the revert atomically rolls this reservation back.
        consumedAttestations[verifiedAttestationId] = true;
        if (!sxcpVerifier.verifyFact(attestation, proof)) revert InvalidSXCPProof();
        emit SXCPAttestationVerified(verifiedAttestationId, expectedScope);
        return verifiedAttestationId;
    }

    /// @notice Validates Base chain and staking-application provenance on a reward commitment.
    /// @dev Accepts only reward commitments emitted by the configured Base staking application.
    function _requireBaseCommitment(RewardTypes.RewardCommitment calldata commitment) internal view {
        if (commitment.sourceChainId != _BASE_CHAIN_ID) revert InvalidSource();
        if (commitment.sourceStakingContract != baseStakingContract) revert InvalidSource();
    }

    /// @notice Derives the application-level replay identifier for an SXCP attestation.
    /// @dev Hashes all fixed attestation fields using canonical ABI encoding.
    function _attestationId(ISXCPVerifier.FactAttestation calldata attestation)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                attestation.intentId,
                attestation.umaId,
                attestation.sourceChainId,
                attestation.destinationChainId,
                attestation.commitmentRef,
                attestation.scopeDigest,
                attestation.replayNonce,
                attestation.expiry,
                attestation.witnessSetEpochId,
                attestation.aegisKeyVersion
            )
        );
    }
}
