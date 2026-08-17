// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ISXCPVerifier} from "../contracts/interfaces/ISXCPVerifier.sol";
import {RewardTypes} from "../contracts/common/RewardTypes.sol";
import {SXCPRewardGateway} from "../contracts/ethereum/SXCPRewardGateway.sol";
import {SynergyStakingRewardVoucher} from "../contracts/ethereum/SynergyStakingRewardVoucher.sol";

/// @dev Test-only gateway verifier. It is never a production ML-DSA/Aegis substitute.
contract TestOnlyAcceptingVerifier is ISXCPVerifier {
    function verifyFact(FactAttestation calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/// @notice Optional Ethereum-mainnet-fork fixture exercising the real v5 reward ledger and gateway role boundary.
contract EthereumForkGatewayRolesTest is Test {
    address internal constant BENEFICIARY = address(0xBEEF);
    address internal constant BASE_STAKING = address(0xB453);
    bytes32 internal constant REGISTER_ACTION = keccak256("SYNERGY_STAKING_REGISTER_PENDING_V1");
    bytes32 internal constant ISSUE_ACTION = keccak256("SYNERGY_STAKING_ISSUE_REWARD_V1");
    bytes32 internal constant CANCEL_ACTION = keccak256("SYNERGY_STAKING_CANCEL_PENDING_V1");

    function testEthereumForkRealLedgerAndGatewayRoles() external {
        string memory rpcUrl = vm.envOr("ETHEREUM_FORK_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        vm.selectFork(vm.createFork(rpcUrl));
        assertEq(block.chainid, 1, "ETHEREUM_FORK_RPC_URL must target Ethereum mainnet");

        SynergyStakingRewardVoucher ledger = new SynergyStakingRewardVoucher(address(this), "");
        TestOnlyAcceptingVerifier verifier = new TestOnlyAcceptingVerifier();
        SXCPRewardGateway gateway = new SXCPRewardGateway(address(verifier), address(ledger), BASE_STAKING);
        ledger.grantRole(ledger.REGISTRAR_ROLE(), address(gateway));
        ledger.grantRole(ledger.ISSUER_ROLE(), address(gateway));

        RewardTypes.RewardCommitment memory commitment = _commitment(bytes32("fork-register"));
        gateway.registerPendingReward(commitment, _attestation(commitment, REGISTER_ACTION, 1), hex"01");
        SynergyStakingRewardVoucher.RewardRecord memory record = ledger.rewardRecord(commitment.rewardId);
        assertEq(uint256(record.state), uint256(SynergyStakingRewardVoucher.RewardState.PENDING));
    }

    function _commitment(bytes32 rewardId) private view returns (RewardTypes.RewardCommitment memory) {
        return RewardTypes.RewardCommitment({
            rewardId: rewardId,
            sourceChainId: 8453,
            sourceStakingContract: BASE_STAKING,
            sourcePositionId: 1,
            beneficiary: BENEFICIARY,
            stakeSource: RewardTypes.StakeSource.UNLOCKED_SNRG,
            sourceAsset: address(0x1234),
            sourceTokenId: 0,
            allocationId: bytes32(0),
            principalNwei: 1_000_000_000,
            rewardNwei: 40_000_000,
            rewardBps: 400,
            startedAt: uint64(block.timestamp - 91 days),
            maturesAt: uint64(block.timestamp - 1 days)
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
