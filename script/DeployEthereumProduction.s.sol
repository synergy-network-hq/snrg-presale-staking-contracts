// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";

import {EthereumAllocationVoucherAdapter} from "../contracts/adapters/EthereumAllocationVoucherAdapter.sol";
import {SynergyEthereumVoucherStaking} from "../contracts/ethereum/SynergyEthereumVoucherStaking.sol";
import {SynergyStakingRewardVoucher} from "../contracts/ethereum/SynergyStakingRewardVoucher.sol";
import {StakingAttestorRegistry} from "../contracts/ethereum/StakingAttestorRegistry.sol";
import {ThresholdStakingAttestationVerifier} from "../contracts/ethereum/ThresholdStakingAttestationVerifier.sol";
import {SXCPRewardGateway} from "../contracts/ethereum/SXCPRewardGateway.sol";

/// @notice Ethereum deployment for the conventional EIP-712 threshold-attestation staking program.
/// @dev Safe role grants and epoch configuration are printed as decoded calldata;
///      no deployment account retains an operational role after deployment.
contract DeployEthereumProduction is Script {
    struct Deployment {
        SynergyStakingRewardVoucher rewardVoucher;
        EthereumAllocationVoucherAdapter voucherAdapter;
        SynergyEthereumVoucherStaking voucherStaking;
        StakingAttestorRegistry attestorRegistry;
        ThresholdStakingAttestationVerifier verifier;
        SXCPRewardGateway gateway;
    }

    function run() external returns (Deployment memory d) {
        require(block.chainid == 1, "Ethereum mainnet only");
        bool broadcast = vm.envOr("BROADCAST", false);
        address admin = vm.envAddress("GOVERNANCE_SAFE");
        address baseStaking = vm.envAddress("BASE_STAKING_ADDRESS");
        address ethVoucher = vm.envAddress("ETHEREUM_PRESALE_VOUCHER");
        uint64 opensAt = uint64(vm.envUint("ETH_ENROLLMENT_OPENS_AT"));
        uint64 closesAt = uint64(vm.envUint("ETH_ENROLLMENT_CLOSES_AT"));
        string memory baseUri = vm.envOr("REWARD_VOUCHER_BASE_URI", string(""));

        _requireAddress(admin, "GOVERNANCE_SAFE");
        _requireAddress(baseStaking, "BASE_STAKING_ADDRESS");
        _requireAddress(ethVoucher, "ETHEREUM_PRESALE_VOUCHER");

        console2.log("=== ETHEREUM DEPLOYMENT CONFIG ===");
        console2.log("broadcast", broadcast);
        console2.log("governance Safe", admin);
        console2.log("Base staking", baseStaking);
        console2.log("Ethereum presale voucher", ethVoucher);
        console2.log("enrollment opens", opensAt);
        console2.log("enrollment closes", closesAt);
        console2.log("reward base URI", baseUri);

        if (!broadcast) {
            console2.log("DRY RUN ONLY: no transaction broadcast.");
            return d;
        }

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        d.rewardVoucher = new SynergyStakingRewardVoucher(admin, baseUri);
        d.voucherAdapter = new EthereumAllocationVoucherAdapter(ethVoucher);
        d.voucherStaking = new SynergyEthereumVoucherStaking(
            admin, address(d.voucherAdapter), address(d.rewardVoucher), opensAt, closesAt
        );
        d.attestorRegistry = new StakingAttestorRegistry(admin);
        d.verifier = new ThresholdStakingAttestationVerifier(address(d.attestorRegistry), baseStaking);
        d.gateway = new SXCPRewardGateway(address(d.verifier), address(d.rewardVoucher), baseStaking);
        vm.stopBroadcast();

        console2.log("SynergyStakingRewardVoucher", address(d.rewardVoucher));
        console2.log("EthereumAllocationVoucherAdapter", address(d.voucherAdapter));
        console2.log("SynergyEthereumVoucherStaking", address(d.voucherStaking));
        console2.log("StakingAttestorRegistry", address(d.attestorRegistry));
        console2.log("ThresholdStakingAttestationVerifier", address(d.verifier));
        console2.log("SXCPRewardGateway", address(d.gateway));
        _printSafeCalldata(d);
    }

    function _printSafeCalldata(Deployment memory d) internal view {
        bytes32 registrar = keccak256("REGISTRAR_ROLE");
        bytes32 issuer = keccak256("ISSUER_ROLE");
        bytes32 pauser = keccak256("PAUSER_ROLE");
        bytes32 keeper = keccak256("KEEPER_ROLE");
        bytes32 metadata = keccak256("METADATA_ROLE");

        console2.log("=== GOVERNANCE SAFE CALLDATA: ROLE GRANTS ===");
        _grant(address(d.rewardVoucher), registrar, address(d.voucherStaking));
        _grant(address(d.rewardVoucher), issuer, address(d.voucherStaking));
        _grant(address(d.rewardVoucher), registrar, address(d.gateway));
        _grant(address(d.rewardVoucher), issuer, address(d.gateway));

        address rewardPauser = vm.envOr("REWARD_PAUSER", address(0));
        address metadataAdmin = vm.envOr("REWARD_METADATA_ADMIN", address(0));
        address ethPauser = vm.envOr("ETH_PAUSER", address(0));
        address ethKeeper = vm.envOr("ETH_KEEPER", address(0));
        if (rewardPauser != address(0)) _grant(address(d.rewardVoucher), pauser, rewardPauser);
        if (metadataAdmin != address(0)) _grant(address(d.rewardVoucher), metadata, metadataAdmin);
        if (ethPauser != address(0)) _grant(address(d.voucherStaking), pauser, ethPauser);
        if (ethKeeper != address(0)) _grant(address(d.voucherStaking), keeper, ethKeeper);

        address[] memory attestors = new address[](3);
        attestors[0] = vm.envAddress("ATTESTOR_1");
        attestors[1] = vm.envAddress("ATTESTOR_2");
        attestors[2] = vm.envAddress("ATTESTOR_3");
        uint64 epoch = uint64(vm.envUint("ATTESTATION_EPOCH"));
        uint16 threshold = uint16(vm.envUint("ATTESTATION_THRESHOLD"));
        require(epoch > 0 && threshold > 0 && threshold <= attestors.length, "attestation config");
        for (uint256 i; i < attestors.length; ++i) _requireAddress(attestors[i], "ATTESTOR");
        _sort(attestors);

        console2.log("configure attestor epoch target", address(d.attestorRegistry));
        console2.logBytes(abi.encodeWithSignature("configureEpoch(uint64,address[],uint16)", epoch, attestors, threshold));
    }

    function _grant(address target, bytes32 role, address account) internal pure {
        console2.log("grantRole target", target);
        console2.log("grantRole account", account);
        console2.logBytes(abi.encodeWithSignature("grantRole(bytes32,address)", role, account));
    }

    function _sort(address[] memory values) private pure {
        for (uint256 i; i < values.length; ++i) {
            for (uint256 j = i + 1; j < values.length; ++j) {
                if (values[i] > values[j]) {
                    address temporary = values[i];
                    values[i] = values[j];
                    values[j] = temporary;
                }
            }
        }
    }

    function _requireAddress(address value, string memory name) private pure {
        require(value != address(0), name);
    }
}
