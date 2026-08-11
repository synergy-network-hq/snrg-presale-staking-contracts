// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title Synergy Staking Entitlement Adapter Interface
/// @author Synergy Network
/// @notice Normalizes a claim-voucher NFT into a canonical 9-decimal SNRG staking entitlement.
/// @dev Implementations are read-only adapters around chain-specific voucher contracts.
interface IEntitlementAdapter {
    /// @notice Returns the voucher contract represented by this adapter.
    /// @return Voucher contract address.
    function voucher() external view returns (address);

    /// @notice Returns the current economic entitlement represented by a voucher token.
    /// @param tokenId Voucher token ID.
    /// @return owner Current voucher owner.
    /// @return entitlementNwei Total SNRG entitlement in canonical 9-decimal nwei.
    /// @return allocationId Canonical economic allocation identifier used for anti-double-counting.
    /// @return consumed True if the underlying claim entitlement has already been consumed.
    function entitlement(uint256 tokenId)
        external
        view
        returns (address owner, uint256 entitlementNwei, bytes32 allocationId, bool consumed);
}
