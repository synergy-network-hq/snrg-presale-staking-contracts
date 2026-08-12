// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title Synergy Staking Attestor Registry Interface
/// @notice Safe-administered, versioned membership used by the EIP-712 verifier.
interface IStakingAttestorRegistry {
    struct Epoch {
        uint16 threshold;
        uint16 attestorCount;
        bool active;
    }

    function epoch(uint64 epochId) external view returns (Epoch memory config);

    function isAttestor(uint64 epochId, address account) external view returns (bool);
}
