// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntitlementAdapter} from "../interfaces/IEntitlementAdapter.sol";

/// @title Ethereum Allocation Voucher Read Interface
/// @author Synergy Network
/// @notice Minimal read interface used by the Ethereum presale staking adapter.
/// @dev The flattened allocation return values are ABI-compatible with the current static Allocation struct.
///      The live production voucher ABI must be verified before deployment.
interface IEthereumAllocationVoucher {
    /// @notice Returns the current ERC-721 owner of a voucher token.
    /// @param tokenId Voucher token ID.
    /// @return owner Current voucher owner.
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /// @notice Returns the immutable/economic allocation data represented by a voucher token.
    /// @dev Return values are flattened so the adapter does not allocate a large temporary Solidity struct.
    /// @param tokenId Voucher token ID.
    function allocationOf(uint256 tokenId)
        external
        view
        returns (
            address buyer,
            uint96 snrgAmountNwei,
            uint128 paymentAmount,
            bytes32 paymentTxHash,
            uint256 paymentChainId,
            uint32 stageId,
            uint128 oraclePriceE8,
            uint128 usdValueE8,
            uint64 paymentTimestamp,
            uint64 nonce,
            uint64 vestingStart,
            uint32 cliffSeconds,
            uint32 durationSeconds,
            uint16 initialUnlockBps,
            bool redeemed
        );

    /// @notice Returns the canonical allocation fingerprint for a voucher token.
    /// @dev The fingerprint should remain stable for the lifetime of the allocation.
    /// @param tokenId Voucher token ID.
    /// @return fingerprint Canonical allocation fingerprint.
    function tokenFingerprint(uint256 tokenId) external view returns (bytes32 fingerprint);
}

/// @title Synergy Ethereum Allocation Voucher Adapter
/// @author Synergy Network
/// @notice Converts an Ethereum presale claim voucher into the canonical entitlement format used by staking.
/// @dev This immutable read-only adapter fails closed: invalid tokens or unsupported source ABI calls revert.
contract EthereumAllocationVoucherAdapter is IEntitlementAdapter {
    /// @inheritdoc IEntitlementAdapter
    address public immutable override voucher;

    /// @notice Reverts when a required address is zero.
    error ZeroAddress();
    /// @notice Reverts when the configured voucher address has no deployed bytecode.
    error InvalidVoucherContract();
    /// @notice Reverts if native ETH is accidentally supplied during deployment.
    error UnexpectedEther();

    /// @notice Emitted once when the immutable adapter dependency is configured.
    /// @param voucherAddress Ethereum voucher contract read by this adapter.
    event VoucherAdapterConfigured(address indexed voucherAddress);

    /// @notice Creates an immutable adapter for an already-deployed Ethereum voucher contract.
    /// @dev The constructor is payable only for deployment-bytecode efficiency; non-zero ETH is rejected.
    /// @param voucher_ Address of the deployed Ethereum allocation voucher contract.
    constructor(address voucher_) payable {
        if (msg.value != 0) revert UnexpectedEther();
        if (voucher_ == address(0)) revert ZeroAddress();
        if (voucher_.code.length == 0) revert InvalidVoucherContract();

        voucher = voucher_;
        emit VoucherAdapterConfigured(voucher_);
    }

    /// @inheritdoc IEntitlementAdapter
    /// @notice Reads current ownership, SNRG entitlement, canonical allocation ID, and redemption state.
    /// @dev The adapter requires the configured voucher to implement ownerOf(), allocationOf(), and
    ///      tokenFingerprint(). This avoids optional-call ambiguity and makes deployment ABI verification explicit.
    function entitlement(uint256 tokenId)
        external
        view
        override
        returns (address owner, uint256 entitlementNwei, bytes32 allocationId, bool consumed)
    {
        IEthereumAllocationVoucher sourceVoucher = IEthereumAllocationVoucher(voucher);

        uint96 snrgAmountNwei;
        bytes32 paymentTxHash;
        uint256 paymentChainId;
        uint64 nonce;
        bool redeemed;

        (
            ,
            snrgAmountNwei,
            ,
            paymentTxHash,
            paymentChainId,
            ,
            ,
            ,
            ,
            nonce,
            ,
            ,
            ,
            ,
            redeemed
        ) = sourceVoucher.allocationOf(tokenId);

        // Avoid ownerOf() after redemption because some ERC-721 implementations burn on consumption.
        owner = redeemed ? address(0) : sourceVoucher.ownerOf(tokenId);
        entitlementNwei = uint256(snrgAmountNwei);

        bytes32 fingerprint = sourceVoucher.tokenFingerprint(tokenId);
        if (fingerprint == bytes32(0)) {
            allocationId = keccak256(abi.encode(paymentChainId, paymentTxHash, nonce));
        } else {
            allocationId = fingerprint;
        }

        consumed = redeemed;
        return (owner, entitlementNwei, allocationId, consumed);
    }
}
