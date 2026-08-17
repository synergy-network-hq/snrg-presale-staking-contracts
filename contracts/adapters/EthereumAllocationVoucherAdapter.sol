// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEntitlementAdapter} from "../interfaces/IEntitlementAdapter.sol";

/// @title Ethereum Allocation Voucher Read Interface
/// @author Synergy Network
/// @notice Exact read interface of SNRGClaimVoucherSoulboundV2's Allocation ABI.
/// @dev Solidity encodes struct returns as tuples. The nested VestingTerms component and every Allocation
///      field below deliberately mirror SNRGClaimVoucherSoulboundV2.sol so the adapter cannot decode an
///      allocation against a stale flattened interface.
interface IEthereumAllocationVoucher {
    struct VestingTerms {
        uint64 vestingStart;
        uint32 cliffSeconds;
        uint32 durationSeconds;
        uint16 initialUnlockBps;
    }

    struct Allocation {
        uint64 ledgerId;
        bytes32 saleIdHash;
        address walletAddress;
        address purchaserAddress;
        bytes32 networkIdHash;
        uint256 paymentChainId;
        bytes32 assetSymbolHash;
        uint96 snrgAmountNwei;
        uint128 paymentAmountRaw;
        address paymentTokenAddress;
        uint8 paymentTokenDecimals;
        bytes32 paymentTxHash;
        uint32 stageFrom;
        uint32 stageTo;
        uint32 stageId;
        uint128 priceUsdE8;
        uint128 usdValueE8;
        uint64 purchaseTimestamp;
        bytes32 sourceHash;
        VestingTerms vesting;
        bool redeemed;
    }

    function ownerOf(uint256 tokenId) external view returns (address owner);

    function allocationOf(uint256 tokenId) external view returns (Allocation memory allocation);

    function tokenFingerprint(uint256 tokenId) external view returns (bytes32 fingerprint);
}

/// @title Synergy Ethereum Allocation Voucher Adapter
/// @author Synergy Network
/// @notice Converts an Ethereum presale claim voucher into the canonical entitlement format used by staking.
/// @dev This immutable read-only adapter fails closed: invalid tokens or unsupported source ABI calls revert.
contract EthereumAllocationVoucherAdapter is IEntitlementAdapter {
    address public immutable override voucher;

    error ZeroAddress();
    error InvalidVoucherContract();
    error UnexpectedEther();
    error MissingTokenFingerprint(uint256 tokenId);

    event VoucherAdapterConfigured(address indexed voucherAddress);

    constructor(address voucher_) payable {
        if (msg.value != 0) revert UnexpectedEther();
        if (voucher_ == address(0)) revert ZeroAddress();
        if (voucher_.code.length == 0) revert InvalidVoucherContract();

        voucher = voucher_;
        emit VoucherAdapterConfigured(voucher_);
    }

    /// @inheritdoc IEntitlementAdapter
    function entitlement(uint256 tokenId)
        external
        view
        override
        returns (address owner, uint256 entitlementNwei, bytes32 allocationId, bool consumed)
    {
        IEthereumAllocationVoucher sourceVoucher = IEthereumAllocationVoucher(voucher);
        IEthereumAllocationVoucher.Allocation memory allocation = sourceVoucher.allocationOf(tokenId);

        // Avoid ownerOf() after redemption because the source voucher can burn on consumption.
        owner = allocation.redeemed ? address(0) : sourceVoucher.ownerOf(tokenId);
        entitlementNwei = uint256(allocation.snrgAmountNwei);

        bytes32 fingerprint = sourceVoucher.tokenFingerprint(tokenId);
        if (fingerprint == bytes32(0)) revert MissingTokenFingerprint(tokenId);
        allocationId = fingerprint;
        consumed = allocation.redeemed;
    }
}
