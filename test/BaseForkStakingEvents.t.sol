// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SynergyBaseStaking} from "../contracts/base/SynergyBaseStaking.sol";
import {StakingTerms} from "../contracts/common/StakingTerms.sol";
import {MockStakeToken, MockBaseVoucherAdapter} from "./fixtures/MockStakeAssets.sol";

/// @notice Optional Base-mainnet-fork fixture. It deploys the unmodified v5 staking implementation
/// and reads the three canonical relay events from the actual v5 ABI.
contract BaseForkStakingEventsTest is Test {
    address internal constant USER = address(0xBEEF);
    bytes32 internal constant OPEN_TOPIC = keccak256(
        "RewardCommitmentOpened(bytes32,uint256,address,uint256,uint8,address,uint256,bytes32,uint256,uint256,uint16,uint64,uint64)"
    );
    bytes32 internal constant SETTLE_TOPIC =
        keccak256("RewardSettlementAuthorized(bytes32,uint256,address,uint256,uint64)");
    bytes32 internal constant CANCEL_TOPIC =
        keccak256("RewardCommitmentCancelled(bytes32,uint256,address,uint256,uint8,uint64)");

    function testBaseForkEmitsAndReadsCanonicalRelayEvents() external {
        string memory rpcUrl = vm.envOr("BASE_FORK_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        vm.selectFork(vm.createFork(rpcUrl));
        assertEq(block.chainid, 8453, "BASE_FORK_RPC_URL must target Base mainnet");

        MockStakeToken unlocked = new MockStakeToken("Test unlocked SNRG", "uSNRG", 18);
        MockStakeToken locked = new MockStakeToken("Test locked SNRG", "lSNRG", 9);
        MockBaseVoucherAdapter adapter = new MockBaseVoucherAdapter(address(0xCAFE));
        SynergyBaseStaking staking = new SynergyBaseStaking(
            address(this), address(unlocked), address(locked), address(adapter), uint64(block.timestamp), 0
        );

        unlocked.mint(USER, 3 ether);
        vm.startPrank(USER);
        unlocked.approve(address(staking), type(uint256).max);

        vm.recordLogs();
        uint256 settledPosition = staking.stakeUnlockedSNRG(1 ether, StakingTerms.Term.THREE_MONTHS);
        Vm.Log[] memory opened = vm.getRecordedLogs();
        assertTrue(_containsTopic(opened, OPEN_TOPIC), "missing RewardCommitmentOpened");

        vm.warp(block.timestamp + 90 days + 1);
        vm.recordLogs();
        staking.settle(settledPosition);
        Vm.Log[] memory settled = vm.getRecordedLogs();
        assertTrue(_containsTopic(settled, SETTLE_TOPIC), "missing RewardSettlementAuthorized");

        vm.recordLogs();
        staking.stakeUnlockedSNRG(1 ether, StakingTerms.Term.SIX_MONTHS);
        staking.earlyUnstake(2);
        Vm.Log[] memory cancelled = vm.getRecordedLogs();
        assertTrue(_containsTopic(cancelled, CANCEL_TOPIC), "missing RewardCommitmentCancelled");
        vm.stopPrank();
    }

    function _containsTopic(Vm.Log[] memory entries, bytes32 topic) private pure returns (bool) {
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length != 0 && entries[i].topics[0] == topic) return true;
        }
        return false;
    }
}
