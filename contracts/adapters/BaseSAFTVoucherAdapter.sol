// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEntitlementAdapter} from "../interfaces/IEntitlementAdapter.sol";

/// @title Base SAFT Claim Voucher Read Interface
/// @author Synergy Network
/// @notice Minimal read interface required by the Base staking entitlement adapter.
/// @dev This interface intentionally contains only the functions consumed by the adapter.
interface IBaseSaftClaimVoucher {
    /// @notice Returns the current ERC-721 owner of a voucher token.
    /// @param tokenId Voucher token ID.
    /// @return owner Current voucher owner.
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /// @notice Returns the economic data represented by a Base SAFT claim voucher.
    /// @param tokenId Voucher token ID.
    /// @return tokenEntitlement Raw SNRG entitlement in the voucher contract's native units.
    /// @return receiptHash Canonical receipt/allocation identifier.
    /// @return mintTimestamp Voucher mint timestamp.
    /// @return claimed True after the voucher entitlement has been claimed.
    /// @return dataHash Auxiliary immutable allocation data hash.
    function getVoucherData(uint256 tokenId)
        external
        view
        returns (
            uint256 tokenEntitlement,
            bytes32 receiptHash,
            uint256 mintTimestamp,
            bool claimed,
            bytes32 dataHash
        );
}

/// @title Synergy Base SAFT Voucher Adapter
/// @author Synergy Network
/// @notice Converts Base SAFT claim-voucher entitlement data into canonical 9-decimal SNRG nwei.
/// @dev Configuration is immutable. Invalid token IDs or source-contract failures revert instead of being
///      converted into synthetic zero-value ownership data, keeping the adapter fail-closed.
contract BaseSAFTVoucherAdapter is IEntitlementAdapter {
    /// @inheritdoc IEntitlementAdapter
    address public immutable override voucher;

    /// @notice Number of decimals used by the source voucher's entitlement field.
    uint8 public immutable entitlementDecimals;

    /// @notice Reverts when a required address is zero.
    error ZeroAddress();
    /// @notice Reverts when the configured entitlement precision is unsupported.
    error InvalidDecimals();
    /// @notice Reverts when the configured voucher address has no deployed bytecode.
    error InvalidVoucherContract();
    /// @notice Reverts when source units cannot be represented exactly in 9-decimal SNRG nwei.
    error ImpreciseEntitlement();
    /// @notice Reverts if native ETH is accidentally supplied during deployment.
    error UnexpectedEther();

    /// @notice Emitted once when the immutable adapter configuration is established.
    /// @param voucherAddress Base SAFT claim voucher read by this adapter.
    /// @param sourceDecimals Source entitlement precision.
    event VoucherAdapterConfigured(address indexed voucherAddress, uint8 sourceDecimals);

    /// @notice Creates an immutable adapter for an already-deployed Base SAFT voucher contract.
    /// @dev The constructor is payable only for deployment-bytecode efficiency; non-zero ETH is rejected.
    /// @param voucher_ Address of the deployed Base SAFT claim voucher.
    /// @param entitlementDecimals_ Decimals used by getVoucherData().tokenEntitlement.
    constructor(address voucher_, uint8 entitlementDecimals_) payable {
        if (msg.value != 0) revert UnexpectedEther();
        if (voucher_ == address(0)) revert ZeroAddress();
        if (voucher_.code.length == 0) revert InvalidVoucherContract();
        if (entitlementDecimals_ > 36) revert InvalidDecimals();

        voucher = voucher_;
        entitlementDecimals = entitlementDecimals_;
        emit VoucherAdapterConfigured(voucher_, entitlementDecimals_);
    }

    /// @inheritdoc IEntitlementAdapter
    /// @notice Reads current ownership, exact SNRG entitlement, allocation ID, and claim state.
    /// @dev Conversion to SNRG nwei is exact. A fractional sub-nwei source amount causes a revert rather than
    ///      silent truncation. Invalid/burned token IDs also revert through the source ownerOf() call.
    function entitlement(uint256 tokenId)
        external
        view
        override
        returns (address owner, uint256 entitlementNwei, bytes32 allocationId, bool consumed)
    {
        IBaseSaftClaimVoucher sourceVoucher = IBaseSaftClaimVoucher(voucher);
        (uint256 rawEntitlement, bytes32 receiptHash, , bool claimed, ) = sourceVoucher.getVoucherData(tokenId);

        // Avoid ownerOf() after consumption because some ERC-721 implementations burn on redemption.
        owner = claimed ? address(0) : sourceVoucher.ownerOf(tokenId);

        if (entitlementDecimals == 9) {
            entitlementNwei = rawEntitlement;
        } else if (entitlementDecimals < 9) {
            uint256 scaleUp = 10 ** uint256(9 - entitlementDecimals);
            entitlementNwei = Math.mulDiv(rawEntitlement, scaleUp, 1);
        } else {
            uint256 scaleDown = 10 ** uint256(entitlementDecimals - 9);
            if (rawEntitlement % scaleDown != 0) revert ImpreciseEntitlement();
            entitlementNwei = Math.mulDiv(rawEntitlement, 1, scaleDown);
        }

        if (receiptHash == bytes32(0)) {
            allocationId = keccak256(abi.encode(block.chainid, voucher, tokenId));
        } else {
            allocationId = receiptHash;
        }

        consumed = claimed;
        return (owner, entitlementNwei, allocationId, consumed);
    }
}
