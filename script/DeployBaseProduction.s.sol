// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {BaseSAFTVoucherAdapter} from "../contracts/adapters/BaseSAFTVoucherAdapter.sol";
import {SynergyBaseStaking} from "../contracts/base/SynergyBaseStaking.sol";

/// @notice Base production deployment. BROADCAST=false is a non-state-changing configuration dry run.
contract DeployBaseProduction is Script {
    struct Deployment {
        BaseSAFTVoucherAdapter voucherAdapter;
        SynergyBaseStaking staking;
    }

    function run() external returns (Deployment memory d) {
        require(block.chainid == 8453, "Base mainnet only");

        bool broadcast = vm.envOr("BROADCAST", false);
        address admin = vm.envAddress("GOVERNANCE_SAFE");
        address voucher = vm.envAddress("BASE_SAFT_VOUCHER");
        uint8 voucherDecimals = uint8(vm.envUint("BASE_SAFT_ENTITLEMENT_DECIMALS"));
        address unlocked = vm.envAddress("BASE_UNLOCKED_SNRG");
        address locked = vm.envAddress("BASE_LOCKED_SNRG");
        uint64 opensAt = uint64(vm.envUint("BASE_ENROLLMENT_OPENS_AT"));
        uint64 closesAt = uint64(vm.envUint("BASE_ENROLLMENT_CLOSES_AT"));

        _requireAddress(admin, "GOVERNANCE_SAFE");
        _requireAddress(voucher, "BASE_SAFT_VOUCHER");
        _requireAddress(unlocked, "BASE_UNLOCKED_SNRG");
        _requireAddress(locked, "BASE_LOCKED_SNRG");

        console2.log("=== BASE DEPLOYMENT CONFIG ===");
        console2.log("broadcast", broadcast);
        console2.log("governance Safe", admin);
        console2.log("Base SAFT voucher", voucher);
        console2.log("SAFT entitlement decimals", voucherDecimals);
        console2.log("unlocked SNRG", unlocked);
        console2.log("locked/Early Supporter SNRG", locked);
        console2.log("enrollment opens", opensAt);
        console2.log("enrollment closes", closesAt);

        if (!broadcast) {
            console2.log("DRY RUN ONLY: no transaction broadcast; rerun with BROADCAST=true after fork gates pass.");
            return d;
        }

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        d.voucherAdapter = new BaseSAFTVoucherAdapter(voucher, voucherDecimals);
        d.staking = new SynergyBaseStaking(
            admin,
            unlocked,
            locked,
            address(d.voucherAdapter),
            opensAt,
            closesAt
        );
        vm.stopBroadcast();

        console2.log("BaseSAFTVoucherAdapter", address(d.voucherAdapter));
        console2.log("SynergyBaseStaking", address(d.staking));
        _printRoleCalldata(address(d.staking));
    }

    function _printRoleCalldata(address staking) internal view {
        address pauser = vm.envAddress("BASE_PAUSER");
        address keeper = vm.envAddress("BASE_KEEPER");
        bytes32 pauserRole = keccak256("PAUSER_ROLE");
        bytes32 keeperRole = keccak256("KEEPER_ROLE");

        console2.log("=== GOVERNANCE SAFE CALLDATA: BASE ===");
        console2.log("target", staking);
        if (pauser != address(0)) {
            console2.log("grant PAUSER_ROLE to", pauser);
            console2.logBytes(abi.encodeWithSignature("grantRole(bytes32,address)", pauserRole, pauser));
        }
        if (keeper != address(0)) {
            console2.log("grant KEEPER_ROLE to", keeper);
            console2.logBytes(abi.encodeWithSignature("grantRole(bytes32,address)", keeperRole, keeper));
        }
    }

    function _requireAddress(address value, string memory name) internal pure {
        require(value != address(0), name);
    }
}
