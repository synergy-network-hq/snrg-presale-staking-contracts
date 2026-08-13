// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BaseSAFTVoucherAdapter} from "../contracts/adapters/BaseSAFTVoucherAdapter.sol";
import {
    EthereumAllocationVoucherAdapter
} from "../contracts/adapters/EthereumAllocationVoucherAdapter.sol";
import {SynergyBaseStaking} from "../contracts/base/SynergyBaseStaking.sol";
import {
    SynergyEthereumVoucherStaking
} from "../contracts/ethereum/SynergyEthereumVoucherStaking.sol";
import {SynergyStakingRewardVoucher} from "../contracts/ethereum/SynergyStakingRewardVoucher.sol";
import {StakingTerms} from "../contracts/common/StakingTerms.sol";
import {RewardTypes} from "../contracts/common/RewardTypes.sol";

/// @notice Mandatory production source-ABI fork smoke tests. Missing env vars are test failures, not skips.
contract ForkSourcesTest is Test {
    address internal constant BASE_UNLOCKED = 0xb695EB367f61D0Af0baAd5d8D96c8aC2A594058F;
    address internal constant BASE_LOCKED = 0x7E6B6D10d6dCDEf7FDF8EAA10717eFB3eb6E3101;
    address internal constant BASE_STAKING = 0xB8d1a3f9B53A824c1bEea0D841A777947cA45825;
    address internal constant ETH_VOUCHER = 0xF913ddCe2Bf4FCA896332086c08B90A1A06fc7A9;
    address internal constant GOVERNANCE_SAFE = 0x72F57B74C0b2D556589CeB393103bea0f631933B;

    function testBaseActualFourSourceBoundaryInputs() external {
        string memory rpc = vm.envString("BASE_RPC_URL");
        uint256 forkBlock = vm.envUint("BASE_FORK_BLOCK");
        address saft = vm.envAddress("BASE_SAFT_VOUCHER");
        uint256 saftTokenId = vm.envUint("BASE_SAFT_TEST_TOKEN_ID");
        address unlockedHolder = vm.envAddress("BASE_UNLOCKED_TEST_HOLDER");
        address lockedHolder = vm.envAddress("BASE_LOCKED_TEST_HOLDER");
        uint8 saftDecimals = uint8(vm.envUint("BASE_SAFT_ENTITLEMENT_DECIMALS"));
        vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 8453);

        assertGt(BASE_UNLOCKED.code.length, 0, "unlocked SNRG missing");
        assertGt(BASE_LOCKED.code.length, 0, "locked SNRG missing");
        assertGt(saft.code.length, 0, "Base SAFT voucher missing");
        assertEq(IERC20Metadata(BASE_UNLOCKED).decimals(), 18, "unlocked decimals");
        assertEq(IERC20Metadata(BASE_LOCKED).decimals(), 9, "locked decimals");
        assertGt(
            IERC20Metadata(BASE_UNLOCKED).balanceOf(unlockedHolder), 0, "unlocked holder empty"
        );
        assertGt(IERC20Metadata(BASE_LOCKED).balanceOf(lockedHolder), 0, "locked holder empty");

        SynergyBaseStaking staking = SynergyBaseStaking(BASE_STAKING);
        assertEq(address(staking.unlockedSNRG()), BASE_UNLOCKED, "production unlocked binding");
        assertEq(address(staking.lockedSNRG()), BASE_LOCKED, "production locked binding");
        assertEq(staking.baseVoucher(), saft, "production SAFT voucher binding");
        assertEq(staking.unlockedDecimals(), 18, "production unlocked normalization");
        assertEq(staking.lockedDecimals(), 9, "production locked normalization");
        BaseSAFTVoucherAdapter adapter =
            BaseSAFTVoucherAdapter(address(staking.baseVoucherAdapter()));
        assertEq(adapter.entitlementDecimals(), saftDecimals, "production SAFT normalization");
        (address owner, uint256 entitlementNwei, bytes32 allocationId, bool consumed) =
            adapter.entitlement(saftTokenId);
        assertFalse(consumed, "Base SAFT fixture consumed");
        assertTrue(owner != address(0), "Base SAFT fixture owner zero");
        assertGt(entitlementNwei, 0, "Base SAFT entitlement zero");
        assertTrue(allocationId != bytes32(0), "Base SAFT allocation zero");

        uint256 unlockedRaw = 1 ether;
        vm.startPrank(unlockedHolder);
        IERC20Metadata(BASE_UNLOCKED).approve(address(staking), unlockedRaw);
        uint256 unlockedPosition =
            staking.stakeUnlockedSNRG(unlockedRaw, StakingTerms.Term.THREE_MONTHS);
        vm.stopPrank();
        (address unlockedOwner, uint256 unlockedPrincipal) =
            _baseOwnerPrincipal(staking, unlockedPosition);
        assertEq(unlockedOwner, unlockedHolder, "unlocked stake owner");
        assertEq(unlockedPrincipal, 1e9, "unlocked normalized principal");

        uint256 lockedRaw = 1e9;
        vm.startPrank(lockedHolder);
        IERC20Metadata(BASE_LOCKED).approve(address(staking), lockedRaw);
        uint256 lockedPosition = staking.stakeLockedSNRG(lockedRaw, StakingTerms.Term.THREE_MONTHS);
        vm.stopPrank();
        (address lockedOwner, uint256 lockedPrincipal) =
            _baseOwnerPrincipal(staking, lockedPosition);
        assertEq(lockedOwner, lockedHolder, "locked stake owner");
        assertEq(lockedPrincipal, 1e9, "locked normalized principal");

        vm.prank(owner);
        uint256 voucherPosition =
            staking.stakeBaseVoucher(saftTokenId, entitlementNwei, StakingTerms.Term.THREE_MONTHS);
        (address voucherStakeOwner, uint256 voucherPrincipal) =
            _baseOwnerPrincipal(staking, voucherPosition);
        assertEq(voucherStakeOwner, owner, "Base voucher stake owner");
        assertEq(voucherPrincipal, entitlementNwei, "Base voucher principal");
    }

    function testEthereumActualPresaleVoucherABI() external {
        string memory rpc = vm.envString("ETHEREUM_RPC_URL");
        uint256 tokenId = vm.envUint("ETHEREUM_VOUCHER_TEST_TOKEN_ID");
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 1);
        assertGt(ETH_VOUCHER.code.length, 0, "Ethereum voucher missing");

        EthereumAllocationVoucherAdapter adapter = new EthereumAllocationVoucherAdapter(ETH_VOUCHER);
        (address owner, uint256 entitlementNwei, bytes32 allocationId, bool consumed) =
            adapter.entitlement(tokenId);
        assertFalse(consumed, "Ethereum voucher fixture consumed");
        assertTrue(owner != address(0), "Ethereum voucher fixture owner zero");
        assertGt(entitlementNwei, 0, "Ethereum voucher entitlement zero");
        assertTrue(allocationId != bytes32(0), "Ethereum voucher allocation zero");

        SynergyStakingRewardVoucher rewardLedger =
            new SynergyStakingRewardVoucher(address(this), "");
        SynergyEthereumVoucherStaking staking = new SynergyEthereumVoucherStaking(
            address(this), address(adapter), address(rewardLedger), uint64(block.timestamp), 0
        );
        rewardLedger.grantRole(rewardLedger.REGISTRAR_ROLE(), address(staking));
        rewardLedger.grantRole(rewardLedger.ISSUER_ROLE(), address(staking));

        vm.prank(owner);
        uint256 positionId =
            staking.stakeVoucher(tokenId, entitlementNwei, StakingTerms.Term.THREE_MONTHS);
        (address voucherStakeOwner, uint256 voucherPrincipal) =
            _ethereumOwnerPrincipal(staking, positionId);
        assertEq(voucherStakeOwner, owner, "Ethereum voucher stake owner");
        assertEq(voucherPrincipal, entitlementNwei, "Ethereum voucher principal");
        assertEq(rewardLedger.totalPendingRewardCount(), 1, "pending reward registered");
    }

    function _baseOwnerPrincipal(SynergyBaseStaking staking, uint256 positionId)
        private
        view
        returns (address owner, uint256 principalNwei)
    {
        RewardTypes.StakeSource source;
        address sourceAsset;
        uint256 sourceTokenId;
        bytes32 allocationId;
        uint256 rawPrincipal;
        uint256 rewardNwei;
        uint16 rewardBps;
        uint64 startedAt;
        uint64 maturesAt;
        SynergyBaseStaking.PositionStatus status;
        bytes32 rewardId;
        (
            ,
            owner,
            source,
            sourceAsset,
            sourceTokenId,
            allocationId,
            rawPrincipal,
            principalNwei,
            rewardNwei,
            rewardBps,
            startedAt,
            maturesAt,
            status,
            rewardId
        ) = staking.positions(positionId);
    }

    function _ethereumOwnerPrincipal(SynergyEthereumVoucherStaking staking, uint256 positionId)
        private
        view
        returns (address owner, uint256 principalNwei)
    {
        uint256 sourceTokenId;
        bytes32 allocationId;
        uint256 rewardNwei;
        uint16 rewardBps;
        uint64 startedAt;
        uint64 maturesAt;
        SynergyEthereumVoucherStaking.PositionStatus status;
        bytes32 rewardId;
        (
            ,
            owner,
            sourceTokenId,
            allocationId,
            principalNwei,
            rewardNwei,
            rewardBps,
            startedAt,
            maturesAt,
            status,
            rewardId
        ) = staking.positions(positionId);
    }
}
