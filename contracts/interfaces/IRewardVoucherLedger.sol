// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {RewardTypes} from "../common/RewardTypes.sol";

/// @title Synergy Staking Reward Voucher Ledger Interface
/// @author Synergy Network
/// @notice Minimal application interface used to register, cancel, and issue staking reward entitlements.
/// @dev Implemented by the canonical Ethereum SynergyStakingRewardVoucher contract.
interface IRewardVoucherLedger {
    /// @notice Registers a new pending staking reward liability.
    /// @param commitment Canonical staking reward facts.
    function registerPendingReward(RewardTypes.RewardCommitment calldata commitment) external;

    /// @notice Cancels an unissued staking reward liability.
    /// @param commitment Canonical staking reward facts.
    /// @param reason Terminal cancellation reason.
    function cancelPendingReward(
        RewardTypes.RewardCommitment calldata commitment,
        RewardTypes.CancellationReason reason
    ) external;

    /// @notice Issues the soulbound Ethereum reward NFT for a matured commitment.
    /// @param commitment Canonical staking reward facts.
    /// @return tokenId Newly issued reward voucher token ID, or the existing token ID for an idempotent replay.
    function issueRewardVoucher(RewardTypes.RewardCommitment calldata commitment)
        external
        returns (uint256 tokenId);
}
