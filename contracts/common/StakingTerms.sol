// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Synergy Presale Staking Terms
/// @author Synergy Network
/// @notice Defines the supported fixed presale staking terms and one-time reward percentages.
/// @dev Rewards are term-total percentages, not APR, APY, or compounding rates. All reward math is
///      performed in canonical 9-decimal SNRG nwei and uses floor rounding at the nwei boundary.
library StakingTerms {
    /// @dev Basis-points denominator used for reward calculations.
    uint256 private constant _BPS_DENOMINATOR = 10_000;

    /// @notice Supported fixed staking periods.
    enum Term {
        THREE_MONTHS,
        SIX_MONTHS,
        NINE_MONTHS,
        TWELVE_MONTHS
    }

    /// @notice Reverts when an unsupported staking term is supplied.
    error InvalidTerm();

    /// @notice Returns the fixed reward rate for a staking term in basis points.
    /// @dev Rates are 400, 600, 800, and 1,000 bps for 3, 6, 9, and 12 months respectively.
    /// @param term Selected fixed staking term.
    /// @return Fixed one-time reward rate in basis points.
    function rewardBps(Term term) internal pure returns (uint16) {
        if (term == Term.THREE_MONTHS) return 400;
        if (term == Term.SIX_MONTHS) return 600;
        if (term == Term.NINE_MONTHS) return 800;
        if (term == Term.TWELVE_MONTHS) return 1_000;
        revert InvalidTerm();
    }

    /// @notice Returns the fixed duration for a staking term in seconds.
    /// @dev Solidity has no calendar-month primitive. The program intentionally uses 90, 180, 270, and 365 days.
    /// @param term Selected fixed staking term.
    /// @return Fixed staking duration in seconds.
    function durationSeconds(Term term) internal pure returns (uint64) {
        if (term == Term.THREE_MONTHS) return uint64(90 days);
        if (term == Term.SIX_MONTHS) return uint64(180 days);
        if (term == Term.NINE_MONTHS) return uint64(270 days);
        if (term == Term.TWELVE_MONTHS) return uint64(365 days);
        revert InvalidTerm();
    }

    /// @notice Calculates the fixed reward for a principal amount expressed in SNRG nwei.
    /// @dev Math.mulDiv avoids intermediate multiplication overflow. Fractional sub-nwei value is rounded down.
    /// @param principalNwei Principal amount in canonical 9-decimal SNRG nwei.
    /// @param term Selected fixed staking term.
    /// @return Fixed staking reward in canonical SNRG nwei.
    function rewardFor(uint256 principalNwei, Term term) internal pure returns (uint256) {
        return rewardForBps(principalNwei, rewardBps(term));
    }

    /// @notice Calculates a reward from an already validated presale basis-points rate.
    /// @param principalNwei Principal amount in canonical 9-decimal SNRG nwei.
    /// @param bps Fixed reward rate in basis points.
    /// @return Reward amount in canonical SNRG nwei.
    function rewardForBps(uint256 principalNwei, uint16 bps) internal pure returns (uint256) {
        return Math.mulDiv(principalNwei, uint256(bps), _BPS_DENOMINATOR);
    }

    /// @notice Returns whether a basis-points value is one of the four authorized presale reward rates.
    /// @param bps Reward rate in basis points.
    /// @return True only for 400, 600, 800, or 1,000 bps.
    /// @notice Returns true only for one of the fixed presale reward rates.
    /// @dev Used by the reward ledger to reject commitments with non-campaign rates.
    function isAllowedRewardBps(uint16 bps) internal pure returns (bool) {
        if (bps == 400) return true;
        if (bps == 600) return true;
        if (bps == 800) return true;
        if (bps == 1_000) return true;
        return false;
    }
}
