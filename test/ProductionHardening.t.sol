// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {SynergyStakingRewardVoucher} from "../contracts/ethereum/SynergyStakingRewardVoucher.sol";
import {StakingAttestorRegistry} from "../contracts/ethereum/StakingAttestorRegistry.sol";
import {ThresholdStakingAttestationVerifier} from "../contracts/ethereum/ThresholdStakingAttestationVerifier.sol";

/// @notice Production-hardening checks that do not rely on fake verifier contracts.
contract ProductionHardeningTest is Test {
    function testEthereumRedemptionIsPermanentlyDisabledPreMainnet() external {
        SynergyStakingRewardVoucher voucher = new SynergyStakingRewardVoucher(address(this), "");
        vm.expectRevert(SynergyStakingRewardVoucher.MainnetRedemptionNotEnabled.selector);
        voucher.redeemForSynergyMainnet(1, bytes32(uint256(1)));
    }

    function testRegistryRejectsDuplicateAttestorsAndInvalidThreshold() external {
        StakingAttestorRegistry registry = new StakingAttestorRegistry(address(this));
        address[] memory duplicate = new address[](2);
        duplicate[0] = address(1);
        duplicate[1] = address(1);
        vm.expectRevert(
            abi.encodeWithSelector(StakingAttestorRegistry.DuplicateAttestor.selector, address(1))
        );
        registry.configureEpoch(1, duplicate, 2);

        address[] memory unique = new address[](2);
        unique[0] = address(1);
        unique[1] = address(2);
        vm.expectRevert(StakingAttestorRegistry.InvalidThreshold.selector);
        registry.configureEpoch(2, unique, 3);
    }

    function testVerifierHasNoAttestorManagementAuthority() external {
        StakingAttestorRegistry registry = new StakingAttestorRegistry(address(this));
        ThresholdStakingAttestationVerifier verifier =
            new ThresholdStakingAttestationVerifier(address(registry), address(0xB453));
        assertEq(verifier.baseStakingContract(), address(0xB453));
        assertEq(address(verifier.attestorRegistry()), address(registry));
    }
}
