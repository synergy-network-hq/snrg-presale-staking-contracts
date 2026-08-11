// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IEntitlementAdapter} from "../interfaces/IEntitlementAdapter.sol";
import {IRewardVoucherLedger} from "../interfaces/IRewardVoucherLedger.sol";
import {RewardTypes} from "../common/RewardTypes.sol";
import {StakingTerms} from "../common/StakingTerms.sol";

/// @title Synergy Ethereum Voucher Staking
/// @author Synergy Network
/// @notice Fixed-term virtual staking for Ethereum presale claim-voucher SNRG entitlements.
/// @dev The voucher NFT itself is not transferred. Active stake amounts reserve the canonical economic allocation,
///      preventing multiple token IDs that represent the same allocation from being double-counted. Users may exit
///      early with no principal penalty; the full position reward is then cancelled. Administrative control uses
///      delayed two-step DEFAULT_ADMIN_ROLE transfer rules.
contract SynergyEthereumVoucherStaking is AccessControlDefaultAdminRules, Pausable, ReentrancyGuard {
    /// @notice Role allowed to pause and unpause new stake enrollment.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role allowed to invalidate an active position after its underlying voucher is consumed.
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint48 private constant _DEFAULT_ADMIN_TRANSFER_DELAY = 2 days;
    uint256 private constant _MAX_PAGE_SIZE = 100;

    /// @notice Immutable entitlement adapter for the Ethereum presale voucher collection.
    IEntitlementAdapter public immutable voucherAdapter;

    /// @notice Immutable source voucher collection returned by voucherAdapter.voucher().
    address public immutable voucher;

    /// @notice Canonical Ethereum reward-voucher liability ledger and NFT issuer.
    IRewardVoucherLedger public immutable rewardVoucherLedger;

    /// @notice Earliest timestamp at which new positions may be opened.
    uint64 public immutable enrollmentOpensAt;

    /// @notice Last timestamp at which new positions may be opened; zero means no configured close.
    uint64 public immutable enrollmentClosesAt;

    uint256 private _nextPositionId = 1;

    /// @notice Lifecycle state of an Ethereum voucher staking position.
    enum PositionStatus {
        NONE,
        ACTIVE,
        SETTLED,
        EARLY_EXITED,
        INVALIDATED
    }

    /// @notice Canonical Ethereum voucher staking position.
    struct Position {
        uint256 positionId;
        address owner;
        uint256 sourceTokenId;
        bytes32 allocationId;
        uint256 principalNwei;
        uint256 rewardNwei;
        uint16 rewardBps;
        uint64 startedAt;
        uint64 maturesAt;
        PositionStatus status;
        bytes32 rewardId;
    }

    /// @notice Position storage keyed by position ID.
    mapping(uint256 positionId => Position position) public positions;

    mapping(address owner => uint256[] positionIds) private _positionsByOwner;

    /// @notice Active virtual principal reserved against a canonical economic allocation ID.
    mapping(bytes32 allocationId => uint256 reservedNwei) public reservedAllocationEntitlementNwei;

    /// @notice Total active virtual principal in canonical 9-decimal SNRG nwei.
    uint256 public totalActivePrincipalNwei;

    /// @notice Total rewards currently promised by active Ethereum voucher staking positions.
    uint256 public totalActiveRewardCommitmentsNwei;

    /// @notice Lifetime rewards successfully converted into reward vouchers at maturity.
    uint256 public totalIssuedRewardCommitmentsNwei;

    /// @notice Lifetime rewards forfeited through voluntary penalty-free early exits.
    uint256 public totalEarlyExitForfeitedRewardCommitmentsNwei;

    /// @notice Lifetime rewards cancelled because the source voucher was consumed before settlement.
    uint256 public totalInvalidatedRewardCommitmentsNwei;

    /// @notice Reverts when a required address is zero.
    error ZeroAddress();
    /// @notice Reverts when a required dependency has no deployed bytecode.
    error NotContract(address target);
    /// @notice Reverts when constructor ETH is non-zero.
    error EtherNotAccepted();
    /// @notice Reverts when the configured enrollment window is invalid.
    error InvalidEnrollmentWindow();
    /// @notice Reverts when new stake enrollment is not currently open.
    error EnrollmentClosed();
    /// @notice Reverts when a requested stake amount is zero.
    error InvalidAmount();
    /// @notice Reverts when the caller does not own the source voucher.
    error NotVoucherOwner();
    /// @notice Reverts when the source voucher has already been consumed.
    error VoucherConsumed();
    /// @notice Reverts when invalidation is attempted before the source voucher is consumed.
    error VoucherNotConsumed();
    /// @notice Reverts when a voucher adapter returns a zero canonical allocation ID.
    error InvalidAllocationId();
    /// @notice Reverts when active reservations plus the requested amount exceed the allocation entitlement.
    error EntitlementExceeded();
    /// @notice Reverts when the voucher's canonical allocation or entitlement changed unexpectedly.
    error VoucherAllocationChanged();
    /// @notice Reverts when a caller does not own the staking position.
    error NotPositionOwner();
    /// @notice Reverts when the staking position is not active.
    error PositionNotActive();
    /// @notice Reverts when normal settlement is attempted before maturity.
    error PositionNotMatured();
    /// @notice Reverts when early exit is attempted at or after maturity.
    error PositionAlreadyMatured();
    /// @notice Reverts when a paginated owner-position query requests too many entries.
    error InvalidPageSize();

    /// @notice Emitted once when immutable Ethereum voucher-staking dependencies are configured.
    event EthereumVoucherStakingConfigured(
        address indexed admin,
        address indexed voucherAdapter,
        address indexed voucher,
        address rewardVoucherLedger,
        uint64 enrollmentOpensAt,
        uint64 enrollmentClosesAt
    );

    /// @notice Emitted when a new virtual voucher stake is opened.
    event VoucherStakeOpened(
        uint256 indexed positionId,
        bytes32 indexed rewardId,
        address indexed owner,
        uint256 sourceTokenId,
        bytes32 allocationId,
        uint256 principalNwei,
        uint256 rewardNwei,
        uint16 rewardBps,
        uint64 startedAt,
        uint64 maturesAt
    );

    /// @notice Emitted when a matured position is settled and its Ethereum reward voucher is issued.
    event VoucherStakeSettled(
        uint256 indexed positionId,
        bytes32 indexed rewardId,
        address indexed owner,
        uint256 rewardVoucherTokenId
    );

    /// @notice Emitted when the owner exits before maturity and forfeits the full reward.
    event VoucherStakeExitedEarly(
        uint256 indexed positionId,
        bytes32 indexed rewardId,
        address indexed owner,
        uint256 principalNwei,
        uint256 forfeitedRewardNwei,
        uint64 exitedAt
    );

    /// @notice Emitted when a keeper invalidates a position whose underlying claim voucher was consumed.
    event VoucherStakeInvalidated(
        uint256 indexed positionId,
        bytes32 indexed rewardId,
        address indexed owner,
        uint256 rewardNwei
    );

    /// @notice Emitted whenever the new-stake pause state changes.
    event NewStakePauseChanged(bool paused, address indexed account);

    /// @notice Deploys the Ethereum voucher staking contract and permanently binds its dependencies.
    /// @dev PAUSER_ROLE and KEEPER_ROLE are intentionally not auto-granted. The default admin should grant them
    ///      to dedicated operational multisigs after deployment. Constructor ETH is rejected.
    /// @param admin Initial delayed DEFAULT_ADMIN_ROLE holder.
    /// @param voucherAdapter_ Deployed Ethereum voucher entitlement adapter.
    /// @param rewardVoucherLedger_ Canonical Ethereum reward voucher ledger.
    /// @param enrollmentOpensAt_ Earliest time users may open positions.
    /// @param enrollmentClosesAt_ Final enrollment time, or zero for no configured close.
    constructor(
        address admin,
        address voucherAdapter_,
        address rewardVoucherLedger_,
        uint64 enrollmentOpensAt_,
        uint64 enrollmentClosesAt_
    ) payable AccessControlDefaultAdminRules(_DEFAULT_ADMIN_TRANSFER_DELAY, admin) {
        if (msg.value != 0) revert EtherNotAccepted();
        if (admin == address(0)) revert ZeroAddress();
        if (voucherAdapter_ == address(0)) revert ZeroAddress();
        if (rewardVoucherLedger_ == address(0)) revert ZeroAddress();
        if (voucherAdapter_.code.length == 0) revert NotContract(voucherAdapter_);
        if (rewardVoucherLedger_.code.length == 0) revert NotContract(rewardVoucherLedger_);
        if (enrollmentClosesAt_ != 0) {
            if (enrollmentClosesAt_ <= enrollmentOpensAt_) revert InvalidEnrollmentWindow();
        }

        IEntitlementAdapter configuredAdapter = IEntitlementAdapter(voucherAdapter_);
        address configuredVoucher = configuredAdapter.voucher();
        if (configuredVoucher == address(0)) revert ZeroAddress();
        if (configuredVoucher.code.length == 0) revert NotContract(configuredVoucher);

        voucherAdapter = configuredAdapter;
        voucher = configuredVoucher;
        rewardVoucherLedger = IRewardVoucherLedger(rewardVoucherLedger_);
        enrollmentOpensAt = enrollmentOpensAt_;
        enrollmentClosesAt = enrollmentClosesAt_;

        emit EthereumVoucherStakingConfigured(
            admin,
            voucherAdapter_,
            configuredVoucher,
            rewardVoucherLedger_,
            enrollmentOpensAt_,
            enrollmentClosesAt_
        );
    }

    /// @notice Opens a fixed-term virtual stake against part or all of a voucher's SNRG entitlement.
    /// @dev No NFT is transferred. Reservation is enforced against allocationId rather than tokenId.
    /// @param tokenId Source Ethereum voucher token ID.
    /// @param amountNwei Amount of the voucher entitlement to stake in canonical SNRG nwei.
    /// @param term Selected 3, 6, 9, or 12 month fixed term.
    /// @return positionId Newly created staking position ID.
    function stakeVoucher(uint256 tokenId, uint256 amountNwei, StakingTerms.Term term)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 positionId)
    {
        _requireEnrollmentOpen();
        if (amountNwei == 0) revert InvalidAmount();

        (
            address voucherOwner,
            uint256 entitlementNwei,
            bytes32 allocationId,
            bool consumed
        ) = voucherAdapter.entitlement(tokenId);

        if (voucherOwner != msg.sender) revert NotVoucherOwner();
        if (consumed) revert VoucherConsumed();
        if (allocationId == bytes32(0)) revert InvalidAllocationId();

        uint256 reservedNwei = reservedAllocationEntitlementNwei[allocationId];
        if (reservedNwei + amountNwei > entitlementNwei) revert EntitlementExceeded();

        positionId = _nextPositionId;
        _nextPositionId = positionId + 1;

        uint64 startedAt = uint64(block.timestamp);
        uint64 maturesAt = startedAt + StakingTerms.durationSeconds(term);
        uint16 rewardBps = StakingTerms.rewardBps(term);
        uint256 rewardNwei = StakingTerms.rewardFor(amountNwei, term);
        if (rewardNwei == 0) revert InvalidAmount();

        bytes32 rewardId = keccak256(
            abi.encode(
                bytes32("SYNERGY_STAKING_REWARD_V1"),
                block.chainid,
                address(this),
                positionId,
                msg.sender,
                RewardTypes.StakeSource.ETHEREUM_VOUCHER,
                voucher,
                tokenId,
                allocationId,
                amountNwei,
                rewardNwei,
                startedAt,
                maturesAt
            )
        );

        Position storage position = positions[positionId];
        position.positionId = positionId;
        position.owner = msg.sender;
        position.sourceTokenId = tokenId;
        position.allocationId = allocationId;
        position.principalNwei = amountNwei;
        position.rewardNwei = rewardNwei;
        position.rewardBps = rewardBps;
        position.startedAt = startedAt;
        position.maturesAt = maturesAt;
        position.status = PositionStatus.ACTIVE;
        position.rewardId = rewardId;

        _positionsByOwner[msg.sender].push(positionId);
        reservedAllocationEntitlementNwei[allocationId] = reservedNwei + amountNwei;
        totalActivePrincipalNwei = totalActivePrincipalNwei + amountNwei;
        totalActiveRewardCommitmentsNwei = totalActiveRewardCommitmentsNwei + rewardNwei;

        RewardTypes.RewardCommitment memory commitment = _commitment(position);
        rewardVoucherLedger.registerPendingReward(commitment);

        emit VoucherStakeOpened(
            positionId,
            rewardId,
            msg.sender,
            tokenId,
            allocationId,
            amountNwei,
            rewardNwei,
            rewardBps,
            startedAt,
            maturesAt
        );
        return positionId;
    }

    /// @notice Settles a matured Ethereum voucher stake and issues its soulbound reward NFT.
    /// @dev Revalidates ownership/allocation state, releases the reservation, updates accounting, then calls the ledger.
    /// @param positionId Active position owned by the caller.
    /// @return rewardVoucherTokenId Ethereum reward voucher token ID.
    function settle(uint256 positionId) external nonReentrant returns (uint256 rewardVoucherTokenId) {
        Position storage position = positions[positionId];
        if (position.owner != msg.sender) revert NotPositionOwner();
        if (position.status != PositionStatus.ACTIVE) revert PositionNotActive();
        if (block.timestamp < position.maturesAt) revert PositionNotMatured();

        (
            address voucherOwner,
            uint256 entitlementNwei,
            bytes32 allocationId,
            bool consumed
        ) = voucherAdapter.entitlement(position.sourceTokenId);

        if (voucherOwner != position.owner) revert NotVoucherOwner();
        if (consumed) revert VoucherConsumed();
        if (allocationId != position.allocationId) revert VoucherAllocationChanged();
        if (entitlementNwei < position.principalNwei) revert VoucherAllocationChanged();

        uint256 reservedNwei = reservedAllocationEntitlementNwei[position.allocationId];
        if (reservedNwei < position.principalNwei) revert VoucherAllocationChanged();

        reservedAllocationEntitlementNwei[position.allocationId] = reservedNwei - position.principalNwei;
        position.status = PositionStatus.SETTLED;
        totalActivePrincipalNwei = totalActivePrincipalNwei - position.principalNwei;
        totalActiveRewardCommitmentsNwei = totalActiveRewardCommitmentsNwei - position.rewardNwei;
        totalIssuedRewardCommitmentsNwei = totalIssuedRewardCommitmentsNwei + position.rewardNwei;

        RewardTypes.RewardCommitment memory commitment = _commitment(position);
        // Interaction is last. The token ID is returned and emitted, but is intentionally not written to
        // staking storage after the external ledger call. Dashboards can resolve it from rewardId on the ledger.
        rewardVoucherTokenId = rewardVoucherLedger.issueRewardVoucher(commitment);

        emit VoucherStakeSettled(positionId, position.rewardId, position.owner, rewardVoucherTokenId);
        return rewardVoucherTokenId;
    }

    /// @notice Exits before maturity with 100% of virtual principal released and no fee or slashing.
    /// @dev The full reward is permanently forfeited and no reward NFT may later be issued for this position.
    /// @param positionId Active position owned by the caller.
    function earlyUnstake(uint256 positionId) external nonReentrant {
        Position storage position = positions[positionId];
        if (position.owner != msg.sender) revert NotPositionOwner();
        if (position.status != PositionStatus.ACTIVE) revert PositionNotActive();
        if (block.timestamp >= position.maturesAt) revert PositionAlreadyMatured();

        uint256 reservedNwei = reservedAllocationEntitlementNwei[position.allocationId];
        if (reservedNwei < position.principalNwei) revert VoucherAllocationChanged();

        reservedAllocationEntitlementNwei[position.allocationId] = reservedNwei - position.principalNwei;
        position.status = PositionStatus.EARLY_EXITED;
        totalActivePrincipalNwei = totalActivePrincipalNwei - position.principalNwei;
        totalActiveRewardCommitmentsNwei = totalActiveRewardCommitmentsNwei - position.rewardNwei;
        totalEarlyExitForfeitedRewardCommitmentsNwei =
            totalEarlyExitForfeitedRewardCommitmentsNwei + position.rewardNwei;

        RewardTypes.RewardCommitment memory commitment = _commitment(position);
        rewardVoucherLedger.cancelPendingReward(commitment, RewardTypes.CancellationReason.EARLY_UNSTAKE);

        emit VoucherStakeExitedEarly(
            position.positionId,
            position.rewardId,
            position.owner,
            position.principalNwei,
            position.rewardNwei,
            uint64(block.timestamp)
        );
    }

    /// @notice Cancels a position whose original voucher entitlement was consumed before settlement.
    /// @dev Restricted to KEEPER_ROLE so arbitrary callers cannot force terminal position state changes.
    /// @param positionId Active voucher staking position to invalidate.
    function invalidateConsumedVoucherPosition(uint256 positionId)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
    {
        Position storage position = positions[positionId];
        if (position.status != PositionStatus.ACTIVE) revert PositionNotActive();

        (, , , bool consumed) = voucherAdapter.entitlement(position.sourceTokenId);
        if (!consumed) revert VoucherNotConsumed();

        uint256 reservedNwei = reservedAllocationEntitlementNwei[position.allocationId];
        if (reservedNwei < position.principalNwei) revert VoucherAllocationChanged();

        reservedAllocationEntitlementNwei[position.allocationId] = reservedNwei - position.principalNwei;
        position.status = PositionStatus.INVALIDATED;
        totalActivePrincipalNwei = totalActivePrincipalNwei - position.principalNwei;
        totalActiveRewardCommitmentsNwei = totalActiveRewardCommitmentsNwei - position.rewardNwei;
        totalInvalidatedRewardCommitmentsNwei = totalInvalidatedRewardCommitmentsNwei + position.rewardNwei;

        RewardTypes.RewardCommitment memory commitment = _commitment(position);
        rewardVoucherLedger.cancelPendingReward(commitment, RewardTypes.CancellationReason.SOURCE_INVALIDATED);

        emit VoucherStakeInvalidated(positionId, position.rewardId, position.owner, position.rewardNwei);
    }

    /// @notice Returns how much of a voucher's canonical allocation remains available to stake.
    /// @dev Returns zero for consumed/invalid allocations and subtracts reservation by allocation ID rather than token ID.
    /// @param tokenId Source voucher token ID.
    /// @return availableNwei Unreserved entitlement in canonical SNRG nwei.
    function availableVoucherEntitlementNwei(uint256 tokenId)
        external
        view
        returns (uint256 availableNwei)
    {
        (, uint256 entitlementNwei, bytes32 allocationId, bool consumed) = voucherAdapter.entitlement(tokenId);
        if (consumed) return 0;
        if (allocationId == bytes32(0)) return 0;

        uint256 reservedNwei = reservedAllocationEntitlementNwei[allocationId];
        if (reservedNwei >= entitlementNwei) return 0;
        return entitlementNwei - reservedNwei;
    }

    /// @notice Returns a full staking position by ID.
    /// @dev Read-only dashboard/audit helper.
    /// @param positionId Position ID.
    /// @return position Stored position data.
    function positionOf(uint256 positionId) external view returns (Position memory position) {
        position = positions[positionId];
        return position;
    }

    /// @notice Returns a bounded page of position IDs owned by an address.
    /// @dev Pagination is capped to prevent unbounded return-array growth.
    /// @param owner Position owner.
    /// @param offset Starting index into the owner's position list.
    /// @param limit Maximum number of IDs to return; capped at 100.
    /// @return page Position IDs in the requested page.
    /// @return nextOffset Offset to use for the next page.
    function positionsOf(address owner, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page, uint256 nextOffset)
    {
        if (limit == 0) revert InvalidPageSize();
        if (limit > _MAX_PAGE_SIZE) revert InvalidPageSize();

        uint256 length = _positionsByOwner[owner].length;
        if (offset >= length) return (new uint256[](0), length);

        uint256 end = offset + limit;
        if (end > length) end = length;
        uint256 count = end - offset;
        page = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            page[i] = _positionsByOwner[owner][offset + i];
            unchecked {
                i = i + 1;
            }
        }
        nextOffset = end;
        return (page, nextOffset);
    }

    /// @notice Pauses creation of new stake positions while preserving user exits and mature settlement.
    /// @dev Restricted to `PAUSER_ROLE`; this deliberately does not pause early unstaking or settlement.
    function pauseNewStakes() external nonReentrant onlyRole(PAUSER_ROLE) {
        _pause();
        emit NewStakePauseChanged(true, msg.sender);
    }

    /// @notice Resumes creation of new stake positions.
    /// @dev Restricted to `PAUSER_ROLE`.
    function unpauseNewStakes() external nonReentrant onlyRole(PAUSER_ROLE) {
        _unpause();
        emit NewStakePauseChanged(false, msg.sender);
    }

    /// @dev Builds the canonical reward commitment from a stored position.
    /// @param position Stored position.
    /// @return commitment Canonical reward commitment consumed by the Ethereum reward ledger.
    function _commitment(Position storage position)
        internal
        view
        returns (RewardTypes.RewardCommitment memory commitment)
    {
        commitment.rewardId = position.rewardId;
        commitment.sourceChainId = block.chainid;
        commitment.sourceStakingContract = address(this);
        commitment.sourcePositionId = position.positionId;
        commitment.beneficiary = position.owner;
        commitment.stakeSource = RewardTypes.StakeSource.ETHEREUM_VOUCHER;
        commitment.sourceAsset = voucher;
        commitment.sourceTokenId = position.sourceTokenId;
        commitment.allocationId = position.allocationId;
        commitment.principalNwei = position.principalNwei;
        commitment.rewardNwei = position.rewardNwei;
        commitment.rewardBps = position.rewardBps;
        commitment.startedAt = position.startedAt;
        commitment.maturesAt = position.maturesAt;
        return commitment;
    }

    /// @notice Validates that new-stake enrollment is currently open.
    /// @dev Reverts unless the immutable enrollment window permits opening a new position now.
    function _requireEnrollmentOpen() internal view {
        if (block.timestamp < enrollmentOpensAt) revert EnrollmentClosed();
        if (enrollmentClosesAt == 0) return;
        if (block.timestamp > enrollmentClosesAt) revert EnrollmentClosed();
    }
}
