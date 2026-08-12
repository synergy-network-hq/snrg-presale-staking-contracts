// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IStakingAttestationVerifier} from "../interfaces/IStakingAttestationVerifier.sol";
import {IStakingAttestorRegistry} from "../interfaces/IStakingAttestorRegistry.sol";

/// @title Synergy Threshold Staking Attestation Verifier
/// @notice Validates a 2-of-3 (or Safe-configured) EIP-712 attestation for a finalized Base event.
/// @dev This contract deliberately has no privileged minting, registry-management,
///      or transaction-submission authority. It only validates canonical signatures.
contract ThresholdStakingAttestationVerifier is EIP712, IStakingAttestationVerifier {
    uint256 public constant BASE_CHAIN_ID = 8_453;
    uint256 public constant ETHEREUM_CHAIN_ID = 1;
    uint256 public constant MAX_SIGNATURES = 32;
    uint256 public constant MAX_SIGNATURE_BYTES = 128;

    bytes32 public constant SOURCE_EVENT_TYPEHASH = keccak256(
        "SYNERGY_STAKING_SOURCE_EVENT_V1(uint256 sourceChainId,address sourceStakingContract,bytes32 sourceTxHash,uint64 sourceLogIndex)"
    );

    bytes32 public constant STAKING_ATTESTATION_TYPEHASH = keccak256(
        "StakingAttestation(uint256 sourceChainId,uint256 destinationChainId,address sourceStakingContract,bytes32 sourceTxHash,uint64 sourceBlockNumber,bytes32 sourceBlockHash,uint64 sourceLogIndex,address staker,address beneficiary,uint8 stakeSourceType,address sourceAsset,uint256 sourceTokenId,bytes32 allocationId,uint256 sourcePositionId,uint256 principalNwei,uint256 rewardNwei,uint16 rewardBps,uint64 startedAt,uint64 maturesAt,bytes32 rewardId,uint8 action,uint8 cancellationReason,uint64 attestationEpoch,uint64 expiry)"
    );

    IStakingAttestorRegistry public immutable attestorRegistry;
    address public immutable baseStakingContract;

    error ZeroAddress();
    error NotContract(address target);

    constructor(address registry, address baseStaking)
        EIP712("Synergy Presale Staking Attestation", "1")
    {
        if (registry == address(0) || baseStaking == address(0)) revert ZeroAddress();
        if (registry.code.length == 0) revert NotContract(registry);
        attestorRegistry = IStakingAttestorRegistry(registry);
        baseStakingContract = baseStaking;
    }

    /// @notice Validates an exact source event and the required number of unique authorized EIP-712 signers.
    /// @dev Recovered signers must be strictly ascending, making duplicate signatures
    ///      impossible to count twice without persistent per-attestation storage.
    function verifyAttestation(StakingAttestation calldata attestation, bytes[] calldata signatures)
        external
        view
        returns (bool valid)
    {
        if (!_validEnvelope(attestation, signatures.length)) return false;

        IStakingAttestorRegistry.Epoch memory config = attestorRegistry.epoch(attestation.attestationEpoch);
        if (!config.active || config.threshold == 0 || config.attestorCount < config.threshold) return false;
        if (signatures.length < config.threshold) return false;

        bytes32 digest = _hashTypedDataV4(_structHash(attestation));
        address previousSigner;
        uint256 validSignatures;
        for (uint256 i; i < signatures.length; ++i) {
            bytes calldata signature = signatures[i];
            if (signature.length == 0 || signature.length > MAX_SIGNATURE_BYTES) return false;
            (address signer, ECDSA.RecoverError recoverError,) = ECDSA.tryRecover(digest, signature);
            if (recoverError != ECDSA.RecoverError.NoError || signer <= previousSigner) return false;
            if (!attestorRegistry.isAttestor(attestation.attestationEpoch, signer)) return false;
            previousSigner = signer;
            unchecked {
                ++validSignatures;
            }
        }
        return validSignatures >= config.threshold;
    }

    function sourceEventId(StakingAttestation calldata attestation) external pure returns (bytes32) {
        return _sourceEventId(attestation);
    }

    function attestationDigest(StakingAttestation calldata attestation)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(_structHash(attestation));
    }

    function _validEnvelope(StakingAttestation calldata attestation, uint256 signatureCount)
        internal
        view
        returns (bool)
    {
        if (block.chainid != ETHEREUM_CHAIN_ID) return false;
        if (attestation.sourceChainId != BASE_CHAIN_ID || attestation.destinationChainId != ETHEREUM_CHAIN_ID) {
            return false;
        }
        if (attestation.sourceStakingContract != baseStakingContract) return false;
        if (
            attestation.sourceTxHash == bytes32(0) || attestation.sourceBlockHash == bytes32(0)
                || attestation.sourceBlockNumber == 0 || attestation.staker == address(0)
                || attestation.beneficiary == address(0) || attestation.rewardId == bytes32(0)
                || attestation.attestationEpoch == 0 || attestation.expiry <= block.timestamp
        ) return false;
        if (uint8(attestation.action) > uint8(RewardAction.CANCEL)) return false;
        if (signatureCount == 0 || signatureCount > MAX_SIGNATURES) return false;
        return true;
    }

    function _sourceEventId(StakingAttestation calldata attestation) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SOURCE_EVENT_TYPEHASH,
                attestation.sourceChainId,
                attestation.sourceStakingContract,
                attestation.sourceTxHash,
                attestation.sourceLogIndex
            )
        );
    }

    function _structHash(StakingAttestation calldata attestation) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                STAKING_ATTESTATION_TYPEHASH,
                attestation.sourceChainId,
                attestation.destinationChainId,
                attestation.sourceStakingContract,
                attestation.sourceTxHash,
                attestation.sourceBlockNumber,
                attestation.sourceBlockHash,
                attestation.sourceLogIndex,
                attestation.staker,
                attestation.beneficiary,
                attestation.stakeSourceType,
                attestation.sourceAsset,
                attestation.sourceTokenId,
                attestation.allocationId,
                attestation.sourcePositionId,
                attestation.principalNwei,
                attestation.rewardNwei,
                attestation.rewardBps,
                attestation.startedAt,
                attestation.maturesAt,
                attestation.rewardId,
                uint8(attestation.action),
                attestation.cancellationReason,
                attestation.attestationEpoch,
                attestation.expiry
            )
        );
    }
}
