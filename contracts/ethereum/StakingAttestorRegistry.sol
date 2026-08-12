// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

import {IStakingAttestorRegistry} from "../interfaces/IStakingAttestorRegistry.sol";

/// @title Synergy Staking Attestor Registry
/// @notice Governance-Safe controlled, immutable-per-epoch EIP-712 attestor membership.
/// @dev Membership changes require a new epoch, so an existing signed message can
///      never be reinterpreted under a changed signer set. Attestors receive no
///      minting, pausing, or administrative authority over staking rewards.
contract StakingAttestorRegistry is AccessControlDefaultAdminRules, IStakingAttestorRegistry {
    uint48 private constant _DEFAULT_ADMIN_TRANSFER_DELAY = 2 days;
    uint16 public constant MAX_ATTESTORS_PER_EPOCH = 32;

    mapping(uint64 epochId => Epoch config) private _epochs;
    mapping(uint64 epochId => mapping(address account => bool enabled)) private _attestors;

    error ZeroAddress();
    error InvalidEpoch();
    error EpochAlreadyConfigured(uint64 epochId);
    error InvalidThreshold();
    error DuplicateAttestor(address account);
    error EpochNotConfigured(uint64 epochId);
    error AttestorNotConfigured(uint64 epochId, address account);

    event AttestorEpochConfigured(uint64 indexed epochId, uint16 threshold, uint16 attestorCount);
    event AttestorEpochStatusChanged(uint64 indexed epochId, bool active);
    event AttestorStatusChanged(uint64 indexed epochId, address indexed attestor, bool active);

    constructor(address governanceSafe) AccessControlDefaultAdminRules(_DEFAULT_ADMIN_TRANSFER_DELAY, governanceSafe) {
        if (governanceSafe == address(0)) revert ZeroAddress();
    }

    /// @notice Creates one immutable membership snapshot controlled by the Governance Safe.
    /// @param epochId Monotonically managed signer-set version.
    /// @param attestors Distinct EOA signer addresses for this epoch.
    /// @param threshold Number of unique signatures needed for a valid attestation.
    function configureEpoch(uint64 epochId, address[] calldata attestors, uint16 threshold)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (epochId == 0) revert InvalidEpoch();
        if (_epochs[epochId].attestorCount != 0) revert EpochAlreadyConfigured(epochId);
        uint256 count = attestors.length;
        if (count == 0 || count > MAX_ATTESTORS_PER_EPOCH) revert InvalidThreshold();
        if (threshold == 0 || threshold > count) revert InvalidThreshold();

        for (uint256 i; i < count; ++i) {
            address attestor = attestors[i];
            if (attestor == address(0)) revert ZeroAddress();
            for (uint256 j; j < i; ++j) {
                if (attestors[j] == attestor) revert DuplicateAttestor(attestor);
            }
            _attestors[epochId][attestor] = true;
        }

        _epochs[epochId] = Epoch({threshold: threshold, attestorCount: uint16(count), active: true});
        emit AttestorEpochConfigured(epochId, threshold, uint16(count));
        emit AttestorEpochStatusChanged(epochId, true);
    }

    /// @notice Disables or re-enables an epoch without altering its signer snapshot.
    /// @dev Disabling is a Safe-controlled incident response; re-enabling does not
    ///      add signers or change the signature threshold.
    function setEpochActive(uint64 epochId, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_epochs[epochId].attestorCount == 0) revert EpochNotConfigured(epochId);
        _epochs[epochId].active = active;
        emit AttestorEpochStatusChanged(epochId, active);
    }

    /// @notice Permanently disables one compromised or retired attestor in an epoch.
    /// @dev A Safe must create a fresh epoch to replace an attestor. Re-enabling an
    ///      old signer would make incident response ambiguous, so it is forbidden.
    function disableAttestor(uint64 epochId, address attestor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_epochs[epochId].attestorCount == 0) revert EpochNotConfigured(epochId);
        if (!_attestors[epochId][attestor]) revert AttestorNotConfigured(epochId, attestor);
        _attestors[epochId][attestor] = false;
        emit AttestorStatusChanged(epochId, attestor, false);
    }

    function epoch(uint64 epochId) external view returns (Epoch memory config) {
        return _epochs[epochId];
    }

    function isAttestor(uint64 epochId, address account) external view returns (bool) {
        return _attestors[epochId][account];
    }
}
