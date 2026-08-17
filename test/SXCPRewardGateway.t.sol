// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ISXCPVerifier} from "../contracts/interfaces/ISXCPVerifier.sol";
import {RewardTypes} from "../contracts/common/RewardTypes.sol";
import {SXCPRewardGateway} from "../contracts/ethereum/SXCPRewardGateway.sol";
import {SynergyStakingRewardVoucher} from "../contracts/ethereum/SynergyStakingRewardVoucher.sol";
import {MockSXCPVerifier} from "./fixtures/MockSXCPVerifier.sol";

/// @notice Exercises the real v5 gateway and ledger with a test-only verifier boundary.
/// @dev ML-DSA verification is covered in the separate integration repository; this file never models it.
contract SXCPRewardGatewayTest is Test {
    address internal constant BENEFICIARY = address(0xBEEF);
    address internal constant BASE_STAKING = address(0xB453);
    bytes32 internal constant REGISTER_ACTION = keccak256("SYNERGY_STAKING_REGISTER_PENDING_V1");
    bytes32 internal constant ISSUE_ACTION = keccak256("SYNERGY_STAKING_ISSUE_REWARD_V1");
    bytes32 internal constant CANCEL_ACTION = keccak256("SYNERGY_STAKING_CANCEL_PENDING_V1");

    SynergyStakingRewardVoucher internal ledger;
    SXCPRewardGateway internal gateway;
    MockSXCPVerifier internal verifier;

    function setUp() external {
        // The ledger rejects a zero `startedAt`; Foundry's default genesis timestamp is not
        // representative of a live Base-originating reward commitment.
        vm.warp(1_700_000_000);
        ledger = new SynergyStakingRewardVoucher(address(this), "");
        verifier = new MockSXCPVerifier();
        gateway = new SXCPRewardGateway(address(verifier), address(ledger), BASE_STAKING);
        ledger.grantRole(ledger.REGISTRAR_ROLE(), address(gateway));
        ledger.grantRole(ledger.ISSUER_ROLE(), address(gateway));
    }

    function testRegister() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("register"), 1 days);
        gateway.registerPendingReward(commitment, _attestation(commitment, REGISTER_ACTION, 1), hex"01");
        assertEq(uint256(ledger.rewardRecord(commitment.rewardId).state), uint256(SynergyStakingRewardVoucher.RewardState.PENDING));
    }

    function testDuplicateRelayRevertsAtGatewayReplayGuard() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("duplicate"), 1 days);
        ISXCPVerifier.FactAttestation memory attestation = _attestation(commitment, REGISTER_ACTION, 2);
        gateway.registerPendingReward(commitment, attestation, hex"01");
        vm.expectRevert(SXCPRewardGateway.AttestationAlreadyConsumed.selector);
        gateway.registerPendingReward(commitment, attestation, hex"01");
    }

    function testCancellationBeforeRegistrationCreatesTerminalTombstone() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("cancel-first"), 1 days);
        gateway.cancelPendingReward(
            commitment,
            RewardTypes.CancellationReason.EARLY_UNSTAKE,
            _attestation(commitment, CANCEL_ACTION, 3),
            hex"01"
        );
        assertEq(uint256(ledger.rewardRecord(commitment.rewardId).state), uint256(SynergyStakingRewardVoucher.RewardState.CANCELLED));
    }

    function testIssuanceBeforeRegistrationRegistersAndIssues() external {
        // A commitment that matures in this block exercises the documented atomic
        // register-and-issue path without time travel.
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("issue-first"), 0);
        uint256 tokenId = gateway.issueRewardVoucher(commitment, _attestation(commitment, ISSUE_ACTION, 4), hex"01");
        assertEq(tokenId, 1);
        assertEq(uint256(ledger.rewardRecord(commitment.rewardId).state), uint256(SynergyStakingRewardVoucher.RewardState.ISSUED));
    }

    function testExpiredProofReverts() external {
        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("expired"), 1 days);
        ISXCPVerifier.FactAttestation memory attestation = _attestation(commitment, REGISTER_ACTION, 5);
        attestation.expiry = uint64(block.timestamp - 1);
        vm.expectRevert(SXCPRewardGateway.ExpiredAttestation.selector);
        gateway.registerPendingReward(commitment, attestation, hex"01");
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

    function _attestation(RewardTypes.RewardCommitment memory commitment, bytes32 action, uint256 nonce)
        private
        view
        returns (ISXCPVerifier.FactAttestation memory)
    {
        bytes32 ref = keccak256(abi.encodePacked("fixture", commitment.rewardId, nonce));
        bytes32 scope = action == CANCEL_ACTION
            ? keccak256(abi.encode(action, commitment, RewardTypes.CancellationReason.EARLY_UNSTAKE, ref))
            : keccak256(abi.encode(action, commitment, ref));
        return ISXCPVerifier.FactAttestation({
            intentId: keccak256(abi.encodePacked("intent", nonce)),
            umaId: keccak256(abi.encodePacked("uma", nonce)),
            sourceChainId: 8453,
            destinationChainId: 1,
            commitmentRef: ref,
            scopeDigest: scope,
            replayNonce: nonce,
            expiry: uint64(block.timestamp + 1 days),
            witnessSetEpochId: 1,
            aegisKeyVersion: 1
        });
    }
}
