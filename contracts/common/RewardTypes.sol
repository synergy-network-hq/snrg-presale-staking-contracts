// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title Synergy Presale Staking Reward Types
/// @author Synergy Network
/// @notice Shared typed data used by Base staking, Ethereum staking, SXCP verification, and reward vouchers.
/// @dev All economic SNRG values in RewardCommitment use canonical 9-decimal SNRG nwei.
library RewardTypes {
    /// @notice Supported economic sources for a staking position.
    enum StakeSource {
        UNLOCKED_SNRG,
        LOCKED_SNRG,
        BASE_VOUCHER,
        ETHEREUM_VOUCHER
    }

    /// @notice Reason an unissued staking reward was permanently cancelled.
    enum CancellationReason {
        NONE,
        EARLY_UNSTAKE,
        SOURCE_INVALIDATED
    }

    /// @notice Canonical immutable economic facts for a staking reward.
    /// @dev This structure is authenticated across chains by SXCP for Base-originating positions.
    struct RewardCommitment {
        bytes32 rewardId;
        uint256 sourceChainId;
        address sourceStakingContract;
        uint256 sourcePositionId;
        address beneficiary;
        StakeSource stakeSource;
        address sourceAsset;
        uint256 sourceTokenId;
        bytes32 allocationId;
        uint256 principalNwei;
        uint256 rewardNwei;
        uint16 rewardBps;
        uint64 startedAt;
        uint64 maturesAt;
    }
}
