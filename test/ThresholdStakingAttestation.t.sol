// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {RewardTypes} from "../contracts/common/RewardTypes.sol";
import {IStakingAttestationVerifier} from "../contracts/interfaces/IStakingAttestationVerifier.sol";
import {StakingAttestorRegistry} from "../contracts/ethereum/StakingAttestorRegistry.sol";
import {ThresholdStakingAttestationVerifier} from "../contracts/ethereum/ThresholdStakingAttestationVerifier.sol";
import {SXCPRewardGateway} from "../contracts/ethereum/SXCPRewardGateway.sol";
import {SynergyStakingRewardVoucher} from "../contracts/ethereum/SynergyStakingRewardVoucher.sol";

/// @notice Exercises the production EIP-712 threshold-attestation path without test verifiers.
contract ThresholdStakingAttestationTest is Test {
    uint256 private constant ATTESTOR_ONE_KEY = 0xA11CE;
    uint256 private constant ATTESTOR_TWO_KEY = 0xB0B;
    uint256 private constant ATTESTOR_THREE_KEY = 0xCAFE;
    uint256 private constant UNAUTHORIZED_KEY = 0xBAD;
    address private constant BASE_STAKING = address(0xB453);
    address private constant BENEFICIARY = address(0xBEEF);

    StakingAttestorRegistry private registry;
    ThresholdStakingAttestationVerifier private verifier;
    SynergyStakingRewardVoucher private ledger;
    SXCPRewardGateway private gateway;

    function setUp() external {
        vm.chainId(1);
        vm.warp(1_800_000_000);

        registry = new StakingAttestorRegistry(address(this));
        address[] memory attestors = new address[](3);
        attestors[0] = vm.addr(ATTESTOR_ONE_KEY);
        attestors[1] = vm.addr(ATTESTOR_TWO_KEY);
        attestors[2] = vm.addr(ATTESTOR_THREE_KEY);
        _sortAddresses(attestors);
        registry.configureEpoch(1, attestors, 2);

        verifier = new ThresholdStakingAttestationVerifier(address(registry), BASE_STAKING);
        ledger = new SynergyStakingRewardVoucher(address(this), "");
        gateway = new SXCPRewardGateway(address(verifier), address(ledger), BASE_STAKING);
        ledger.grantRole(ledger.REGISTRAR_ROLE(), address(gateway));
        ledger.grantRole(ledger.ISSUER_ROLE(), address(gateway));
    }

    function testValidTwoOfThreeAttestationAndGatewayRegistration() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("register"), 1 days);
        IStakingAttestationVerifier.StakingAttestation memory attestation = _attestation(
            commitment, IStakingAttestationVerifier.RewardAction.REGISTER, 0, 1
        );
        bytes[] memory signatures = _sign(attestation, ATTESTOR_ONE_KEY, ATTESTOR_TWO_KEY);

        assertTrue(verifier.verifyAttestation(attestation, signatures));
        gateway.registerPendingReward(commitment, attestation, signatures);
        assertEq(
            uint256(ledger.rewardRecord(commitment.rewardId).state),
            uint256(SynergyStakingRewardVoucher.RewardState.PENDING)
        );
    }

    function testOneOfThreeUnauthorizedAndDuplicateSignersAreRejected() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("threshold"), 1 days);
        IStakingAttestationVerifier.StakingAttestation memory attestation = _attestation(
            commitment, IStakingAttestationVerifier.RewardAction.REGISTER, 0, 2
        );
        bytes[] memory oneSignature = _sign(attestation, ATTESTOR_ONE_KEY, 0);
        assertFalse(verifier.verifyAttestation(attestation, oneSignature));

        bytes[] memory unauthorized = _sign(attestation, ATTESTOR_ONE_KEY, UNAUTHORIZED_KEY);
        assertFalse(verifier.verifyAttestation(attestation, unauthorized));

        bytes[] memory duplicate = new bytes[](2);
        bytes[] memory valid = _sign(attestation, ATTESTOR_ONE_KEY, ATTESTOR_TWO_KEY);
        duplicate[0] = valid[0];
        duplicate[1] = valid[0];
        assertFalse(verifier.verifyAttestation(attestation, duplicate));
    }

    function testWrongSourceAndModifiedEconomicFieldsAreRejected() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("binding"), 1 days);
        IStakingAttestationVerifier.StakingAttestation memory attestation = _attestation(
            commitment, IStakingAttestationVerifier.RewardAction.REGISTER, 0, 3
        );
        bytes[] memory signatures = _sign(attestation, ATTESTOR_ONE_KEY, ATTESTOR_TWO_KEY);

        attestation.sourceChainId = 1;
        assertFalse(verifier.verifyAttestation(attestation, signatures));
        attestation.sourceChainId = 8453;
        attestation.beneficiary = address(0xF00D);
        assertFalse(verifier.verifyAttestation(attestation, signatures));
        attestation.beneficiary = BENEFICIARY;
        attestation.rewardNwei += 1;
        assertFalse(verifier.verifyAttestation(attestation, signatures));
    }

    function testEverySignedLocatorAndEconomicFieldRejectsMutation() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("mutation"), 1 days);
        IStakingAttestationVerifier.StakingAttestation memory canonical = _attestation(
            commitment, IStakingAttestationVerifier.RewardAction.REGISTER, 0, 31
        );
        bytes[] memory signatures = _sign(canonical, ATTESTOR_ONE_KEY, ATTESTOR_TWO_KEY);
        IStakingAttestationVerifier.StakingAttestation memory changed = canonical;

        changed.destinationChainId = 8453;
        assertFalse(verifier.verifyAttestation(changed, signatures));
        changed = canonical;
        changed.sourceStakingContract = address(0x9999);
        assertFalse(verifier.verifyAttestation(changed, signatures));
        changed = canonical;
        changed.sourceTxHash = keccak256("changed-tx");
        assertFalse(verifier.verifyAttestation(changed, signatures));
        changed = canonical;
        changed.sourceLogIndex += 1;
        assertFalse(verifier.verifyAttestation(changed, signatures));
        changed = canonical;
        changed.sourceBlockHash = keccak256("changed-block");
        assertFalse(verifier.verifyAttestation(changed, signatures));
        changed = canonical;
        changed.sourcePositionId += 1;
        assertFalse(verifier.verifyAttestation(changed, signatures));
        changed = canonical;
        changed.principalNwei += 1;
        assertFalse(verifier.verifyAttestation(changed, signatures));
        changed = canonical;
        changed.rewardId = keccak256("changed-reward");
        assertFalse(verifier.verifyAttestation(changed, signatures));
    }

    function testIncorrectThresholdAndExpiredAttestationFail() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("expiry"), 1 days);
        IStakingAttestationVerifier.StakingAttestation memory attestation = _attestation(
            commitment, IStakingAttestationVerifier.RewardAction.REGISTER, 0, 32
        );
        bytes[] memory signatures = _sign(attestation, ATTESTOR_ONE_KEY, ATTESTOR_TWO_KEY);

        address[] memory secondEpoch = new address[](3);
        secondEpoch[0] = vm.addr(ATTESTOR_ONE_KEY);
        secondEpoch[1] = vm.addr(ATTESTOR_TWO_KEY);
        secondEpoch[2] = vm.addr(ATTESTOR_THREE_KEY);
        _sortAddresses(secondEpoch);
        registry.configureEpoch(2, secondEpoch, 3);
        attestation.attestationEpoch = 2;
        signatures = _sign(attestation, ATTESTOR_ONE_KEY, ATTESTOR_TWO_KEY);
        assertFalse(verifier.verifyAttestation(attestation, signatures));

        attestation = _attestation(commitment, IStakingAttestationVerifier.RewardAction.REGISTER, 0, 33);
        attestation.expiry = uint64(block.timestamp);
        signatures = _sign(attestation, ATTESTOR_ONE_KEY, ATTESTOR_TWO_KEY);
        assertFalse(verifier.verifyAttestation(attestation, signatures));
        vm.expectRevert(SXCPRewardGateway.ExpiredAttestation.selector);
        gateway.registerPendingReward(commitment, attestation, signatures);
    }

    function testGatewayRejectsAttestationCommitmentSubstitutionAndReplay() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("replay"), 1 days);
        IStakingAttestationVerifier.StakingAttestation memory attestation = _attestation(
            commitment, IStakingAttestationVerifier.RewardAction.REGISTER, 0, 4
        );
        bytes[] memory signatures = _sign(attestation, ATTESTOR_ONE_KEY, ATTESTOR_TWO_KEY);

        RewardTypes.RewardCommitment memory substituted = commitment;
        substituted.principalNwei += 1;
        vm.expectRevert(SXCPRewardGateway.AttestationCommitmentMismatch.selector);
        gateway.registerPendingReward(substituted, attestation, signatures);

        // The correctly bound commitment is accepted exactly once; the same
        // source log cannot be replayed afterwards.
        // Solidity memory structs alias here, so rebuild the canonical payload
        // rather than accidentally submitting the substituted amount again.
        commitment = _commitment(bytes32("replay"), 1 days);
        gateway.registerPendingReward(commitment, attestation, signatures);
        bytes32 sourceEventId = verifier.sourceEventId(attestation);
        assertTrue(gateway.consumedSourceEvents(sourceEventId));
        vm.expectRevert(
            abi.encodeWithSelector(SXCPRewardGateway.SourceEventAlreadyConsumed.selector, sourceEventId)
        );
        gateway.registerPendingReward(commitment, attestation, signatures);
    }

    function testDisabledAttestorCannotSatisfyAnExistingEpoch() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("disabled"), 1 days);
        IStakingAttestationVerifier.StakingAttestation memory attestation = _attestation(
            commitment, IStakingAttestationVerifier.RewardAction.REGISTER, 0, 6
        );
        bytes[] memory signatures = _sign(attestation, ATTESTOR_ONE_KEY, ATTESTOR_TWO_KEY);

        registry.disableAttestor(1, vm.addr(ATTESTOR_ONE_KEY));
        assertFalse(verifier.verifyAttestation(attestation, signatures));
    }

    function testGatewayIssuesMatureRewardAndDirectMintFails() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("issue"), 0);
        IStakingAttestationVerifier.StakingAttestation memory attestation = _attestation(
            commitment, IStakingAttestationVerifier.RewardAction.ISSUE, 0, 5
        );
        bytes[] memory signatures = _sign(attestation, ATTESTOR_TWO_KEY, ATTESTOR_THREE_KEY);

        uint256 tokenId = gateway.issueRewardVoucher(commitment, attestation, signatures);
        assertEq(tokenId, 1);
        assertEq(ledger.ownerOf(tokenId), BENEFICIARY);

        RewardTypes.RewardCommitment memory second = _commitment(bytes32("direct"), 0);
        vm.expectRevert();
        ledger.issueRewardVoucher(second);
    }

    function _commitment(bytes32 rewardId, uint64 maturityOffset)
        private
        view
        returns (RewardTypes.RewardCommitment memory)
    {
        return RewardTypes.RewardCommitment({
            rewardId: rewardId,
            sourceChainId: 8453,
            sourceStakingContract: BASE_STAKING,
            sourcePositionId: uint256(rewardId),
            beneficiary: BENEFICIARY,
            stakeSource: RewardTypes.StakeSource.UNLOCKED_SNRG,
            sourceAsset: address(0x1234),
            sourceTokenId: 0,
            allocationId: bytes32(0),
            principalNwei: 1_000_000_000,
            rewardNwei: 40_000_000,
            rewardBps: 400,
            startedAt: uint64(block.timestamp - 1),
            maturesAt: uint64(block.timestamp + maturityOffset)
        });
    }

    function _attestation(
        RewardTypes.RewardCommitment memory commitment,
        IStakingAttestationVerifier.RewardAction action,
        uint8 cancellationReason,
        uint64 logIndex
    ) private view returns (IStakingAttestationVerifier.StakingAttestation memory) {
        return IStakingAttestationVerifier.StakingAttestation({
            sourceChainId: 8453,
            destinationChainId: 1,
            sourceStakingContract: BASE_STAKING,
            sourceTxHash: keccak256(abi.encode(commitment.rewardId, logIndex)),
            sourceBlockNumber: 12_345_678,
            sourceBlockHash: keccak256("base-block"),
            sourceLogIndex: logIndex,
            staker: BENEFICIARY,
            beneficiary: BENEFICIARY,
            stakeSourceType: uint8(commitment.stakeSource),
            sourceAsset: commitment.sourceAsset,
            sourceTokenId: commitment.sourceTokenId,
            allocationId: commitment.allocationId,
            sourcePositionId: commitment.sourcePositionId,
            principalNwei: commitment.principalNwei,
            rewardNwei: commitment.rewardNwei,
            rewardBps: commitment.rewardBps,
            startedAt: commitment.startedAt,
            maturesAt: commitment.maturesAt,
            rewardId: commitment.rewardId,
            action: action,
            cancellationReason: cancellationReason,
            attestationEpoch: 1,
            expiry: uint64(block.timestamp + 1 days)
        });
    }

    function _sign(
        IStakingAttestationVerifier.StakingAttestation memory attestation,
        uint256 firstKey,
        uint256 secondKey
    ) private returns (bytes[] memory signatures) {
        uint256 count = secondKey == 0 ? 1 : 2;
        signatures = new bytes[](count);
        bytes32 digest = verifier.attestationDigest(attestation);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(firstKey, digest);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        if (count == 1) return signatures;

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(secondKey, digest);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        if (vm.addr(firstKey) > vm.addr(secondKey)) {
            bytes memory temp = signatures[0];
            signatures[0] = signatures[1];
            signatures[1] = temp;
        }
    }

    function _sortAddresses(address[] memory values) private pure {
        for (uint256 i; i < values.length; ++i) {
            for (uint256 j = i + 1; j < values.length; ++j) {
                if (values[i] > values[j]) {
                    address temp = values[i];
                    values[i] = values[j];
                    values[j] = temp;
                }
            }
        }
    }
}
