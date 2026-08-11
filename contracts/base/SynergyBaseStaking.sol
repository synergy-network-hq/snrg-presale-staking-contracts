// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IEntitlementAdapter} from "../interfaces/IEntitlementAdapter.sol";
import {RewardTypes} from "../common/RewardTypes.sol";
import {StakingTerms} from "../common/StakingTerms.sol";

/// @title SynergyBaseStaking
/// @author Synergy Network
/// @notice Fixed-term presale staking for Base SNRG, Early Supporter/locked SNRG,
///         and Base claim-voucher SNRG entitlements.
/// @dev Reward NFTs are not minted on Base. This contract emits canonical facts
///      that SXCP can attest for Ethereum-side pending reward accounting, issuance,
///      and cancellation. Administrative control uses OpenZeppelin's delayed,
///      two-step default-admin rules. ERC20 principal is held by this contract;
///      voucher staking is virtual and reserves entitlement by canonical allocation ID.
contract SynergyBaseStaking is AccessControlDefaultAdminRules, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to pause and unpause creation of new stake positions.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role allowed to invalidate consumed voucher positions defensively.
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 private constant _ETHEREUM_CHAIN_ID = 1;
    uint8 private constant _SNRG_NWEI_DECIMALS = 9;
    uint256 private constant _MAX_PAGE_SIZE = 100;
    uint48 private constant _DEFAULT_ADMIN_TRANSFER_DELAY = 2 days;

    /// @notice The live/unlocked SNRG token accepted by this staking contract.
    IERC20 public immutable unlockedSNRG;

    /// @notice The Early Supporter/locked SNRG token accepted by this staking contract.
    IERC20 public immutable lockedSNRG;

    /// @notice Native decimals reported by the unlocked SNRG token.
    uint8 public immutable unlockedDecimals;

    /// @notice Native decimals reported by the locked SNRG token.
    uint8 public immutable lockedDecimals;

    /// @notice Adapter that normalizes the Base claim-voucher NFT into SNRG nwei entitlement.
    IEntitlementAdapter public immutable baseVoucherAdapter;

    /// @notice Voucher contract bound to the entitlement adapter at deployment.
    address public immutable baseVoucher;

    /// @notice Timestamp at which new staking enrollment begins.
    uint64 public immutable enrollmentOpensAt;

    /// @notice Timestamp after which new staking enrollment is closed. Zero means no closing timestamp.
    uint64 public immutable enrollmentClosesAt;

    uint256 private _nextPositionId = 1;

    /// @notice Lifecycle state of a stake position.
    enum PositionStatus {
        NONE,
        ACTIVE,
        SETTLED,
        EARLY_EXITED,
        INVALIDATED
    }

    /// @notice Canonical Base staking position.
    struct Position {
        uint256 positionId;
        address owner;
        RewardTypes.StakeSource source;
        address sourceAsset;
        uint256 sourceTokenId;
        bytes32 allocationId;
        uint256 rawPrincipal;
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

    /// @notice Total active voucher entitlement reserved for a canonical economic allocation.
    /// @dev Reservation is keyed by allocation ID, not token ID, to prevent two voucher token IDs
    ///      representing the same allocation from being counted twice.
    mapping(bytes32 allocationId => uint256 reservedNwei) public reservedAllocationEntitlementNwei;

    /// @notice Total active principal across ERC20 and virtual voucher positions, normalized to SNRG nwei.
    uint256 public totalActivePrincipalNwei;

    /// @notice Total reward amount currently promised by active positions, normalized to SNRG nwei.
    uint256 public totalActiveRewardCommitmentsNwei;

    /// @notice Lifetime rewards associated with positions successfully settled at maturity.
    uint256 public totalSettledRewardCommitmentsNwei;

    /// @notice Lifetime rewards forfeited by voluntary early unstaking.
    uint256 public totalEarlyExitForfeitedRewardCommitmentsNwei;

    /// @notice Lifetime rewards invalidated because a voucher source was consumed before settlement.
    uint256 public totalInvalidatedRewardCommitmentsNwei;

    /// @notice Raw unlocked-SNRG principal currently owed to active stakers.
    uint256 public totalActiveUnlockedRaw;

    /// @notice Raw locked-SNRG principal currently owed to active stakers.
    uint256 public totalActiveLockedRaw;

    /// @notice Reverts when a required address is zero.
    error ZeroAddress();
    /// @notice Reverts when a required local dependency does not contain deployed bytecode.
    error NotContract(address target);
    /// @notice Reverts when the unlocked and locked SNRG token addresses are identical.
    error DuplicateTokenAddress();
    /// @notice Reverts when the configured enrollment opening/closing timestamps are inconsistent.
    error InvalidEnrollmentWindow();
    /// @notice Reverts when a user attempts to open a position outside the enrollment window.
    error EnrollmentClosed();
    /// @notice Reverts when a stake amount or derived canonical amount is zero.
    error InvalidAmount();
    /// @notice Reverts when an ERC-20 decimal configuration cannot be safely normalized.
    error InvalidTokenDecimals();
    /// @notice Reverts when an ERC-20 amount cannot be represented exactly in canonical SNRG nwei.
    error ImpreciseAmount();
    /// @notice Reverts when an ERC-20 transfer changes balances by less than the requested principal.
    error FeeOnTransferNotSupported();
    /// @notice Reverts when the caller does not own the requested staking position.
    error NotPositionOwner();
    /// @notice Reverts when a staking position is not in the ACTIVE state required by the operation.
    error PositionNotActive();
    /// @notice Reverts when normal settlement is requested before the position maturity timestamp.
    error PositionNotMatured();
    /// @notice Reverts when voluntary early unstaking is requested at or after maturity.
    error PositionAlreadyMatured();
    /// @notice Reverts when a position source is not valid for the requested operation.
    error InvalidStakeSource();
    /// @notice Reverts when the caller does not own the source presale claim voucher.
    error NotVoucherOwner();
    /// @notice Reverts when a voucher entitlement has already been consumed.
    error VoucherConsumed();
    /// @notice Reverts when defensive invalidation is requested for a voucher that is not consumed.
    error VoucherNotConsumed();
    /// @notice Reverts when immutable voucher allocation data no longer matches the staking position.
    error VoucherAllocationChanged();
    /// @notice Reverts when an entitlement adapter does not return a canonical allocation identifier.
    error InvalidAllocationId();
    /// @notice Reverts when requested virtual principal exceeds the unreserved allocation entitlement.
    error EntitlementExceeded();
    /// @notice Reverts if native ETH is supplied to the constructor.
    error EtherNotAccepted();
    /// @notice Reverts when an owner-position pagination request has an invalid page size.
    error InvalidPageSize();
    /// @notice Reverts when the staking contract's ERC-20 balance is below tracked principal liabilities.
    error InsolventToken(address token, uint256 balance, uint256 required);

    /// @notice Emitted once after all immutable Base staking dependencies and enrollment settings are validated.
    event BaseStakingConfigured(
        address indexed admin,
        address indexed unlockedSNRG,
        address indexed lockedSNRG,
        address baseVoucherAdapter,
        address baseVoucher,
        uint64 enrollmentOpensAt,
        uint64 enrollmentClosesAt
    );

    /// @notice Emitted after a new Base staking position is fully recorded and any ERC-20 principal is received.
    event StakeOpened(
        uint256 indexed positionId,
        bytes32 indexed rewardId,
        address indexed owner,
        RewardTypes.StakeSource source,
        address sourceAsset,
        uint256 sourceTokenId,
        bytes32 allocationId,
        uint256 principalNwei,
        uint256 rewardNwei,
        uint16 rewardBps,
        uint64 startedAt,
        uint64 maturesAt
    );

    /// @notice Canonical Base fact SXCP should attest to register a pending reward on Ethereum.
    event RewardCommitmentOpened(
        bytes32 indexed rewardId,
        uint256 indexed positionId,
        address indexed beneficiary,
        uint256 destinationChainId,
        RewardTypes.StakeSource source,
        address sourceAsset,
        uint256 sourceTokenId,
        bytes32 allocationId,
        uint256 principalNwei,
        uint256 rewardNwei,
        uint16 rewardBps,
        uint64 startedAt,
        uint64 maturesAt
    );

    /// @notice Canonical Base fact SXCP should attest before the Ethereum reward NFT is issued.
    event RewardSettlementAuthorized(
        bytes32 indexed rewardId,
        uint256 indexed positionId,
        address indexed beneficiary,
        uint256 rewardNwei,
        uint64 settledAt
    );

    /// @notice Emitted when a position owner exits before maturity and forfeits the entire reward.
    event StakeExitedEarly(
        uint256 indexed positionId,
        bytes32 indexed rewardId,
        address indexed owner,
        RewardTypes.StakeSource source,
        uint256 principalNwei,
        uint256 forfeitedRewardNwei,
        uint64 exitedAt
    );

    /// @notice Canonical terminal Base fact SXCP should attest to cancel an unissued reward.
    event RewardCommitmentCancelled(
        bytes32 indexed rewardId,
        uint256 indexed positionId,
        address indexed beneficiary,
        uint256 rewardNwei,
        RewardTypes.CancellationReason reason,
        uint64 cancelledAt
    );

    /// @notice Emitted when a keeper invalidates a reward after the source voucher is independently consumed.
    event RewardCommitmentInvalidated(
        bytes32 indexed rewardId,
        uint256 indexed positionId,
        address indexed beneficiary,
        uint256 rewardNwei,
        uint64 invalidatedAt
    );

    /// @notice Emitted in addition to OpenZeppelin's Paused/Unpaused events for dashboard clarity.
    event NewStakePauseChanged(bool paused, address indexed account);

    /// @notice Emitted by each public staking entry point after the position is successfully created.
    /// @dev This compact event complements StakeOpened and makes the externally-invoked state transition explicit.
    event StakeEntryConfirmed(
        uint256 indexed positionId,
        address indexed owner,
        RewardTypes.StakeSource indexed source
    );

    /// @notice Emitted whenever tracked raw ERC-20 principal liability changes.
    event ERC20PrincipalLiabilityChanged(
        RewardTypes.StakeSource indexed source,
        uint256 previousRawLiability,
        uint256 newRawLiability
    );

    /// @notice Emitted after an exact ERC-20 principal deposit is received into staking custody.
    event ERC20PrincipalReceived(
        address indexed token,
        address indexed owner,
        uint256 rawAmount
    );

    /// @notice Emitted after an exact ERC-20 principal amount is returned to a position owner.
    event ERC20PrincipalReturned(
        uint256 indexed positionId,
        address indexed token,
        address indexed owner,
        uint256 rawAmount
    );

    /// @notice Deploys the Base staking contract and permanently binds its accepted assets and enrollment window.
    /// @dev The constructor is payable only to avoid unnecessary deployment bytecode; any non-zero ETH is rejected.
    ///      PAUSER_ROLE and KEEPER_ROLE are intentionally not auto-granted. The default admin should grant them
    ///      to dedicated operational addresses/multisigs immediately after deployment.
    /// @param admin Initial DEFAULT_ADMIN_ROLE holder. This role transfers through a delayed two-step process.
    /// @param unlockedSNRG_ Live/unlocked SNRG token contract.
    /// @param lockedSNRG_ Early Supporter/locked SNRG token contract.
    /// @param baseVoucherAdapter_ Entitlement adapter for the Base claim-voucher collection.
    /// @param enrollmentOpensAt_ Earliest timestamp at which users may open new positions.
    /// @param enrollmentClosesAt_ Latest enrollment timestamp, or zero for no configured closing time.
    constructor(
        address admin,
        address unlockedSNRG_,
        address lockedSNRG_,
        address baseVoucherAdapter_,
        uint64 enrollmentOpensAt_,
        uint64 enrollmentClosesAt_
    ) payable AccessControlDefaultAdminRules(_DEFAULT_ADMIN_TRANSFER_DELAY, admin) {
        if (msg.value != 0) revert EtherNotAccepted();
        if (admin == address(0)) revert ZeroAddress();
        if (unlockedSNRG_ == address(0)) revert ZeroAddress();
        if (lockedSNRG_ == address(0)) revert ZeroAddress();
        if (baseVoucherAdapter_ == address(0)) revert ZeroAddress();

        if (unlockedSNRG_ == lockedSNRG_) revert DuplicateTokenAddress();
        if (unlockedSNRG_.code.length == 0) revert NotContract(unlockedSNRG_);
        if (lockedSNRG_.code.length == 0) revert NotContract(lockedSNRG_);
        if (baseVoucherAdapter_.code.length == 0) revert NotContract(baseVoucherAdapter_);

        if (enrollmentClosesAt_ != 0) {
            if (enrollmentClosesAt_ <= enrollmentOpensAt_) revert InvalidEnrollmentWindow();
        }

        IERC20Metadata unlockedMetadata = IERC20Metadata(unlockedSNRG_);
        IERC20Metadata lockedMetadata = IERC20Metadata(lockedSNRG_);
        uint8 unlockedTokenDecimals = unlockedMetadata.decimals();
        uint8 lockedTokenDecimals = lockedMetadata.decimals();

        if (unlockedTokenDecimals > 36) revert InvalidTokenDecimals();
        if (lockedTokenDecimals > 36) revert InvalidTokenDecimals();

        IEntitlementAdapter adapter = IEntitlementAdapter(baseVoucherAdapter_);
        address voucherAddress = adapter.voucher();
        if (voucherAddress == address(0)) revert ZeroAddress();
        if (voucherAddress.code.length == 0) revert NotContract(voucherAddress);

        unlockedSNRG = IERC20(unlockedSNRG_);
        lockedSNRG = IERC20(lockedSNRG_);
        unlockedDecimals = unlockedTokenDecimals;
        lockedDecimals = lockedTokenDecimals;
        baseVoucherAdapter = adapter;
        baseVoucher = voucherAddress;
        enrollmentOpensAt = enrollmentOpensAt_;
        enrollmentClosesAt = enrollmentClosesAt_;

        emit BaseStakingConfigured(
            admin,
            unlockedSNRG_,
            lockedSNRG_,
            baseVoucherAdapter_,
            voucherAddress,
            enrollmentOpensAt_,
            enrollmentClosesAt_
        );
    }

    /// @notice Stakes live/unlocked SNRG for one of the fixed presale terms.
    /// @dev The staking contract must first have sufficient ERC20 allowance from the caller.
    /// @param rawAmount Amount in the unlocked token's native decimals.
    /// @param term Fixed staking term selected by the user.
    /// @return positionId Newly created position ID.
    function stakeUnlockedSNRG(uint256 rawAmount, StakingTerms.Term term)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 positionId)
    {
        positionId = _stakeERC20(
            unlockedSNRG,
            unlockedDecimals,
            rawAmount,
            RewardTypes.StakeSource.UNLOCKED_SNRG,
            term
        );
        emit StakeEntryConfirmed(positionId, msg.sender, RewardTypes.StakeSource.UNLOCKED_SNRG);
        return positionId;
    }

    /// @notice Stakes Early Supporter/locked SNRG for one of the fixed presale terms.
    /// @dev The locked token must recognize this contract as an authorized staking endpoint if its transfer rules require it.
    /// @param rawAmount Amount in the locked token's native decimals.
    /// @param term Fixed staking term selected by the user.
    /// @return positionId Newly created position ID.
    function stakeLockedSNRG(uint256 rawAmount, StakingTerms.Term term)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 positionId)
    {
        positionId = _stakeERC20(
            lockedSNRG,
            lockedDecimals,
            rawAmount,
            RewardTypes.StakeSource.LOCKED_SNRG,
            term
        );
        emit StakeEntryConfirmed(positionId, msg.sender, RewardTypes.StakeSource.LOCKED_SNRG);
        return positionId;
    }

    /// @notice Virtually stakes part of an unconsumed Base claim-voucher SNRG entitlement.
    /// @dev No NFT is transferred. The amount is reserved against the voucher's canonical allocation ID.
    /// @param tokenId Claim-voucher NFT token ID.
    /// @param amountNwei SNRG entitlement amount to reserve, expressed in 9-decimal nwei.
    /// @param term Fixed staking term selected by the user.
    /// @return positionId Newly created position ID.
    function stakeBaseVoucher(uint256 tokenId, uint256 amountNwei, StakingTerms.Term term)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 positionId)
    {
        _requireEnrollmentOpen();
        if (amountNwei == 0) revert InvalidAmount();

        IEntitlementAdapter adapter = baseVoucherAdapter;
        (
            address voucherOwner,
            uint256 entitlementNwei,
            bytes32 allocationId,
            bool consumed
        ) = adapter.entitlement(tokenId);

        if (voucherOwner == address(0)) revert NotVoucherOwner();
        if (voucherOwner != msg.sender) revert NotVoucherOwner();
        if (consumed) revert VoucherConsumed();
        if (allocationId == bytes32(0)) revert InvalidAllocationId();
        if (entitlementNwei == 0) revert InvalidAmount();

        uint256 reserved = reservedAllocationEntitlementNwei[allocationId];
        uint256 updatedReserved = reserved + amountNwei;
        if (updatedReserved > entitlementNwei) revert EntitlementExceeded();
        reservedAllocationEntitlementNwei[allocationId] = updatedReserved;

        positionId = _openPosition(
            msg.sender,
            RewardTypes.StakeSource.BASE_VOUCHER,
            baseVoucher,
            tokenId,
            allocationId,
            0,
            amountNwei,
            term
        );
        emit StakeEntryConfirmed(positionId, msg.sender, RewardTypes.StakeSource.BASE_VOUCHER);
        return positionId;
    }

    /// @notice Settles a matured position and returns/releases 100% of principal.
    /// @dev A matured position receives its full fixed reward commitment. ERC20 accounting state is updated
    ///      before the external token transfer; a failed transfer reverts the entire transaction atomically.
    /// @param positionId Position to settle.
    function settle(uint256 positionId) external nonReentrant {
        Position storage p = positions[positionId];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (p.status != PositionStatus.ACTIVE) revert PositionNotActive();
        if (block.timestamp < p.maturesAt) revert PositionNotMatured();

        if (p.source == RewardTypes.StakeSource.BASE_VOUCHER) {
            (
                address voucherOwner,
                uint256 entitlementNwei,
                bytes32 allocationId,
                bool consumed
            ) = baseVoucherAdapter.entitlement(p.sourceTokenId);

            if (voucherOwner != p.owner) revert NotVoucherOwner();
            if (consumed) revert VoucherConsumed();
            if (allocationId != p.allocationId) revert VoucherAllocationChanged();

            uint256 reserved = reservedAllocationEntitlementNwei[allocationId];
            if (reserved < p.principalNwei) revert VoucherAllocationChanged();
            if (entitlementNwei < reserved) revert VoucherAllocationChanged();

            reservedAllocationEntitlementNwei[allocationId] = reserved - p.principalNwei;
        } else {
            if (p.source == RewardTypes.StakeSource.UNLOCKED_SNRG) {
                _decreaseERC20Liability(p.source, p.rawPrincipal);
            } else {
                if (p.source == RewardTypes.StakeSource.LOCKED_SNRG) {
                    _decreaseERC20Liability(p.source, p.rawPrincipal);
                } else {
                    revert InvalidStakeSource();
                }
            }
        }

        p.status = PositionStatus.SETTLED;
        totalActivePrincipalNwei = totalActivePrincipalNwei - p.principalNwei;
        totalActiveRewardCommitmentsNwei = totalActiveRewardCommitmentsNwei - p.rewardNwei;
        totalSettledRewardCommitmentsNwei = totalSettledRewardCommitmentsNwei + p.rewardNwei;

        if (p.source != RewardTypes.StakeSource.BASE_VOUCHER) {
            _returnERC20Principal(p);
        }

        emit RewardSettlementAuthorized(
            p.rewardId,
            p.positionId,
            p.owner,
            p.rewardNwei,
            uint64(block.timestamp)
        );
    }

    /// @notice Exits an active position before maturity with no principal penalty and no fee.
    /// @dev The position's entire reward is permanently forfeited. This remains callable while new staking is paused.
    ///      If the underlying ERC20 itself is paused, its transfer can revert; because the transaction is atomic,
    ///      the position remains ACTIVE and can be retried after the token is transferable again.
    /// @param positionId Active position to exit early.
    function earlyUnstake(uint256 positionId) external nonReentrant {
        Position storage p = positions[positionId];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (p.status != PositionStatus.ACTIVE) revert PositionNotActive();
        if (block.timestamp >= p.maturesAt) revert PositionAlreadyMatured();

        if (p.source == RewardTypes.StakeSource.BASE_VOUCHER) {
            uint256 reserved = reservedAllocationEntitlementNwei[p.allocationId];
            if (reserved < p.principalNwei) revert VoucherAllocationChanged();
            reservedAllocationEntitlementNwei[p.allocationId] = reserved - p.principalNwei;
        } else {
            if (p.source == RewardTypes.StakeSource.UNLOCKED_SNRG) {
                _decreaseERC20Liability(p.source, p.rawPrincipal);
            } else {
                if (p.source == RewardTypes.StakeSource.LOCKED_SNRG) {
                    _decreaseERC20Liability(p.source, p.rawPrincipal);
                } else {
                    revert InvalidStakeSource();
                }
            }
        }

        p.status = PositionStatus.EARLY_EXITED;
        totalActivePrincipalNwei = totalActivePrincipalNwei - p.principalNwei;
        totalActiveRewardCommitmentsNwei = totalActiveRewardCommitmentsNwei - p.rewardNwei;
        totalEarlyExitForfeitedRewardCommitmentsNwei =
            totalEarlyExitForfeitedRewardCommitmentsNwei + p.rewardNwei;

        if (p.source != RewardTypes.StakeSource.BASE_VOUCHER) {
            _returnERC20Principal(p);
        }

        uint64 exitedAt = uint64(block.timestamp);
        emit StakeExitedEarly(
            p.positionId,
            p.rewardId,
            p.owner,
            p.source,
            p.principalNwei,
            p.rewardNwei,
            exitedAt
        );

        emit RewardCommitmentCancelled(
            p.rewardId,
            p.positionId,
            p.owner,
            p.rewardNwei,
            RewardTypes.CancellationReason.EARLY_UNSTAKE,
            exitedAt
        );
    }

    /// @notice Invalidates reward eligibility for a Base voucher position after the source voucher is consumed.
    /// @dev Restricted to KEEPER_ROLE to prevent unrestricted callers from mutating staking state. The keeper cannot
    ///      redirect any principal or reward; it can only finalize the defensive state transition after the adapter
    ///      independently proves the voucher is consumed.
    /// @param positionId Active Base-voucher position to invalidate.
    function invalidateConsumedVoucherPosition(uint256 positionId)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
    {
        Position storage p = positions[positionId];
        if (p.status != PositionStatus.ACTIVE) revert PositionNotActive();
        if (p.source != RewardTypes.StakeSource.BASE_VOUCHER) revert InvalidStakeSource();

        (, , , bool consumed) = baseVoucherAdapter.entitlement(p.sourceTokenId);
        if (!consumed) revert VoucherNotConsumed();

        uint256 reserved = reservedAllocationEntitlementNwei[p.allocationId];
        if (reserved < p.principalNwei) revert VoucherAllocationChanged();
        reservedAllocationEntitlementNwei[p.allocationId] = reserved - p.principalNwei;

        p.status = PositionStatus.INVALIDATED;
        totalActivePrincipalNwei = totalActivePrincipalNwei - p.principalNwei;
        totalActiveRewardCommitmentsNwei = totalActiveRewardCommitmentsNwei - p.rewardNwei;
        totalInvalidatedRewardCommitmentsNwei = totalInvalidatedRewardCommitmentsNwei + p.rewardNwei;

        uint64 invalidatedAt = uint64(block.timestamp);
        emit RewardCommitmentInvalidated(
            p.rewardId,
            p.positionId,
            p.owner,
            p.rewardNwei,
            invalidatedAt
        );

        emit RewardCommitmentCancelled(
            p.rewardId,
            p.positionId,
            p.owner,
            p.rewardNwei,
            RewardTypes.CancellationReason.SOURCE_INVALIDATED,
            invalidatedAt
        );
    }

    /// @notice Returns the currently unreserved SNRG entitlement for a Base claim voucher.
    /// @dev Returns zero for consumed vouchers or adapters that return a zero allocation ID.
    /// @param tokenId Claim-voucher token ID.
    /// @return availableNwei Available entitlement in 9-decimal SNRG nwei.
    function availableBaseVoucherEntitlementNwei(uint256 tokenId)
        external
        view
        returns (uint256 availableNwei)
    {
        (, uint256 entitlementNwei, bytes32 allocationId, bool consumed) =
            baseVoucherAdapter.entitlement(tokenId);

        if (!consumed) {
            if (allocationId != bytes32(0)) {
                uint256 reserved = reservedAllocationEntitlementNwei[allocationId];
                if (entitlementNwei > reserved) {
                    availableNwei = entitlementNwei - reserved;
                }
            }
        }
        return availableNwei;
    }

    /// @notice Returns the number of staking positions created by an owner.
    /// @dev Reverts for the zero address to avoid ambiguous dashboard queries.
    /// @param owner Address whose position count is requested.
    /// @return count Number of position IDs associated with the owner.
    function positionCountOf(address owner) external view returns (uint256 count) {
        if (owner == address(0)) revert ZeroAddress();
        count = _positionsByOwner[owner].length;
        return count;
    }

    /// @notice Returns a bounded page of position IDs for an owner.
    /// @dev Pagination prevents unbounded return-data growth for wallets with many positions.
    /// @param owner Address whose positions are requested.
    /// @param offset Zero-based starting index.
    /// @param limit Maximum number of IDs to return; must be between 1 and 100.
    /// @return page Position IDs in the requested slice.
    function positionIdsOf(address owner, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page)
    {
        if (owner == address(0)) revert ZeroAddress();
        if (limit == 0) revert InvalidPageSize();
        if (limit > _MAX_PAGE_SIZE) revert InvalidPageSize();

        uint256 length = _positionsByOwner[owner].length;
        if (offset >= length) {
            page = new uint256[](0);
        } else {
            uint256 remaining = length - offset;
            uint256 pageLength = limit < remaining ? limit : remaining;
            page = new uint256[](pageLength);

            for (uint256 i; i < pageLength; ) {
                page[i] = _positionsByOwner[owner][offset + i];
                unchecked {
                    ++i;
                }
            }
        }
        return page;
    }

    /// @notice Returns the canonical reward commitment associated with a position.
    /// @dev The returned commitment is the normalized payload consumed by SXCP/Ethereum accounting.
    /// @param positionId Position ID to inspect.
    /// @return commitment Reward commitment used by SXCP and the Ethereum reward ledger.
    function rewardCommitment(uint256 positionId)
        external
        view
        returns (RewardTypes.RewardCommitment memory commitment)
    {
        Position storage p = positions[positionId];
        commitment.rewardId = p.rewardId;
        commitment.sourceChainId = block.chainid;
        commitment.sourceStakingContract = address(this);
        commitment.sourcePositionId = p.positionId;
        commitment.beneficiary = p.owner;
        commitment.stakeSource = p.source;
        commitment.sourceAsset = p.sourceAsset;
        commitment.sourceTokenId = p.sourceTokenId;
        commitment.allocationId = p.allocationId;
        commitment.principalNwei = p.principalNwei;
        commitment.rewardNwei = p.rewardNwei;
        commitment.rewardBps = p.rewardBps;
        commitment.startedAt = p.startedAt;
        commitment.maturesAt = p.maturesAt;
        return commitment;
    }

    /// @notice Returns current ERC20 custody balances and active raw liabilities.
    /// @dev A healthy contract has each token balance greater than or equal to its corresponding liability.
    /// @return unlockedBalance Current unlocked-SNRG token balance held by this contract.
    /// @return unlockedLiability Raw unlocked-SNRG principal owed to active positions.
    /// @return lockedBalance Current locked-SNRG token balance held by this contract.
    /// @return lockedLiability Raw locked-SNRG principal owed to active positions.
    function custodySolvency()
        external
        view
        returns (
            uint256 unlockedBalance,
            uint256 unlockedLiability,
            uint256 lockedBalance,
            uint256 lockedLiability
        )
    {
        unlockedBalance = unlockedSNRG.balanceOf(address(this));
        unlockedLiability = totalActiveUnlockedRaw;
        lockedBalance = lockedSNRG.balanceOf(address(this));
        lockedLiability = totalActiveLockedRaw;
        return (unlockedBalance, unlockedLiability, lockedBalance, lockedLiability);
    }

    /// @notice Pauses creation of new stake positions while preserving settlement and early-exit paths.
    /// @dev Only PAUSER_ROLE may call this function.
    function pauseNewStakes() external nonReentrant onlyRole(PAUSER_ROLE) {
        _pause();
        emit NewStakePauseChanged(true, msg.sender);
    }

    /// @notice Re-enables creation of new stake positions.
    /// @dev Only PAUSER_ROLE may call this function.
    function unpauseNewStakes() external nonReentrant onlyRole(PAUSER_ROLE) {
        _unpause();
        emit NewStakePauseChanged(false, msg.sender);
    }

    /// @dev Pulls an exact ERC20 amount into custody, verifies no transfer tax, normalizes to nwei,
    ///      updates raw-token liability, and opens the corresponding fixed-term position.
    function _stakeERC20(
        IERC20 token,
        uint8 tokenDecimals,
        uint256 rawAmount,
        RewardTypes.StakeSource source,
        StakingTerms.Term term
    ) internal returns (uint256 positionId) {
        _requireEnrollmentOpen();
        if (rawAmount == 0) revert InvalidAmount();

        uint256 principalNwei;
        if (tokenDecimals == _SNRG_NWEI_DECIMALS) {
            principalNwei = rawAmount;
        } else if (tokenDecimals < _SNRG_NWEI_DECIMALS) {
            uint256 factorUp = 10 ** uint256(_SNRG_NWEI_DECIMALS - tokenDecimals);
            principalNwei = rawAmount * factorUp;
        } else {
            uint256 factorDown = 10 ** uint256(tokenDecimals - _SNRG_NWEI_DECIMALS);
            if (mulmod(rawAmount, 1, factorDown) != 0) revert ImpreciseAmount();
            principalNwei = Math.mulDiv(rawAmount, 1, factorDown);
        }
        if (principalNwei == 0) revert InvalidAmount();

        // Pull and verify the exact principal before committing staking-accounting effects. The external
        // entry points are nonReentrant, so a non-standard ERC-20 callback cannot enter another staking
        // transition while this transfer is in progress. Any later revert atomically rolls the transfer back.
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), rawAmount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance) revert FeeOnTransferNotSupported();
        if (afterBalance - beforeBalance != rawAmount) revert FeeOnTransferNotSupported();
        emit ERC20PrincipalReceived(address(token), msg.sender, rawAmount);

        if (source == RewardTypes.StakeSource.UNLOCKED_SNRG) {
            uint256 previousRawLiability = totalActiveUnlockedRaw;
            uint256 newRawLiability = previousRawLiability + rawAmount;
            totalActiveUnlockedRaw = newRawLiability;
            emit ERC20PrincipalLiabilityChanged(source, previousRawLiability, newRawLiability);
            _assertSolvent(unlockedSNRG, newRawLiability);
        } else if (source == RewardTypes.StakeSource.LOCKED_SNRG) {
            uint256 previousRawLiability = totalActiveLockedRaw;
            uint256 newRawLiability = previousRawLiability + rawAmount;
            totalActiveLockedRaw = newRawLiability;
            emit ERC20PrincipalLiabilityChanged(source, previousRawLiability, newRawLiability);
            _assertSolvent(lockedSNRG, newRawLiability);
        } else {
            revert InvalidStakeSource();
        }

        positionId = _openPosition(
            msg.sender,
            source,
            address(token),
            0,
            bytes32(0),
            rawAmount,
            principalNwei,
            term
        );
        return positionId;
    }

    /// @notice Creates the canonical staking position and fixed reward commitment.
    /// @dev Creates a canonical position and reward commitment. Reward math is exact to one nwei:
    ///      any stake whose configured percentage would create a fractional nwei is rejected.
    function _openPosition(
        address owner,
        RewardTypes.StakeSource source,
        address sourceAsset,
        uint256 sourceTokenId,
        bytes32 allocationId,
        uint256 rawPrincipal,
        uint256 principalNwei,
        StakingTerms.Term term
    ) internal returns (uint256 positionId) {
        if (owner == address(0)) revert ZeroAddress();
        if (sourceAsset == address(0)) revert ZeroAddress();
        if (principalNwei == 0) revert InvalidAmount();

        positionId = _nextPositionId;
        _nextPositionId = positionId + 1;

        uint64 startedAt = uint64(block.timestamp);
        uint64 maturesAt = startedAt + StakingTerms.durationSeconds(term);
        uint16 rewardBps = StakingTerms.rewardBps(term);

        uint256 rewardNwei = StakingTerms.rewardFor(principalNwei, term);
        if (rewardNwei == 0) revert InvalidAmount();

        bytes32 rewardId = keccak256(
            abi.encode(
                bytes32("SYNERGY_STAKING_REWARD_V1"),
                block.chainid,
                address(this),
                positionId,
                owner,
                uint8(source),
                sourceAsset,
                sourceTokenId,
                allocationId,
                principalNwei,
                rewardNwei,
                startedAt,
                maturesAt
            )
        );

        Position storage p = positions[positionId];
        p.positionId = positionId;
        p.owner = owner;
        p.source = source;
        p.sourceAsset = sourceAsset;
        p.sourceTokenId = sourceTokenId;
        p.allocationId = allocationId;
        p.rawPrincipal = rawPrincipal;
        p.principalNwei = principalNwei;
        p.rewardNwei = rewardNwei;
        p.rewardBps = rewardBps;
        p.startedAt = startedAt;
        p.maturesAt = maturesAt;
        p.status = PositionStatus.ACTIVE;
        p.rewardId = rewardId;

        _positionsByOwner[owner].push(positionId);
        totalActivePrincipalNwei = totalActivePrincipalNwei + principalNwei;
        totalActiveRewardCommitmentsNwei = totalActiveRewardCommitmentsNwei + rewardNwei;

        emit StakeOpened(
            positionId,
            rewardId,
            owner,
            source,
            sourceAsset,
            sourceTokenId,
            allocationId,
            principalNwei,
            rewardNwei,
            rewardBps,
            startedAt,
            maturesAt
        );

        emit RewardCommitmentOpened(
            rewardId,
            positionId,
            owner,
            _ETHEREUM_CHAIN_ID,
            source,
            sourceAsset,
            sourceTokenId,
            allocationId,
            principalNwei,
            rewardNwei,
            rewardBps,
            startedAt,
            maturesAt
        );
        return positionId;
    }

    /// @notice Validates that the current timestamp is inside the campaign enrollment window.
    /// @dev Rejects new enrollment outside the configured campaign window.
    function _requireEnrollmentOpen() internal view {
        uint256 timestamp = block.timestamp;
        if (timestamp < enrollmentOpensAt) revert EnrollmentClosed();

        uint64 closesAt = enrollmentClosesAt;
        if (closesAt != 0) {
            if (timestamp > closesAt) revert EnrollmentClosed();
        }
    }

    /// @notice Decreases the selected ERC-20 raw-principal liability before principal return.
    /// @dev Decreases the raw ERC20 liability before principal is returned.
    function _decreaseERC20Liability(RewardTypes.StakeSource source, uint256 rawPrincipal) internal {
        if (source == RewardTypes.StakeSource.UNLOCKED_SNRG) {
            if (totalActiveUnlockedRaw < rawPrincipal) {
                revert InsolventToken(address(unlockedSNRG), unlockedSNRG.balanceOf(address(this)), totalActiveUnlockedRaw);
            }
            _assertSolvent(unlockedSNRG, totalActiveUnlockedRaw);
            uint256 previousRawLiability = totalActiveUnlockedRaw;
            uint256 newRawLiability = previousRawLiability - rawPrincipal;
            totalActiveUnlockedRaw = newRawLiability;
            emit ERC20PrincipalLiabilityChanged(source, previousRawLiability, newRawLiability);
        } else if (source == RewardTypes.StakeSource.LOCKED_SNRG) {
            if (totalActiveLockedRaw < rawPrincipal) {
                revert InsolventToken(address(lockedSNRG), lockedSNRG.balanceOf(address(this)), totalActiveLockedRaw);
            }
            _assertSolvent(lockedSNRG, totalActiveLockedRaw);
            uint256 previousRawLiability = totalActiveLockedRaw;
            uint256 newRawLiability = previousRawLiability - rawPrincipal;
            totalActiveLockedRaw = newRawLiability;
            emit ERC20PrincipalLiabilityChanged(source, previousRawLiability, newRawLiability);
        } else {
            revert InvalidStakeSource();
        }
    }

    /// @notice Returns the exact ERC-20 principal owed to a position owner.
    /// @dev Returns ERC20 principal and verifies the recipient received the exact amount.
    function _returnERC20Principal(Position storage p) internal {
        IERC20 token;
        if (p.source == RewardTypes.StakeSource.UNLOCKED_SNRG) {
            token = unlockedSNRG;
        } else if (p.source == RewardTypes.StakeSource.LOCKED_SNRG) {
            token = lockedSNRG;
        } else {
            revert InvalidStakeSource();
        }

        uint256 ownerBalanceBefore = token.balanceOf(p.owner);
        token.safeTransfer(p.owner, p.rawPrincipal);
        uint256 ownerBalanceAfter = token.balanceOf(p.owner);

        if (ownerBalanceAfter < ownerBalanceBefore) revert FeeOnTransferNotSupported();
        if (ownerBalanceAfter - ownerBalanceBefore != p.rawPrincipal) revert FeeOnTransferNotSupported();
        emit ERC20PrincipalReturned(p.positionId, address(token), p.owner, p.rawPrincipal);
    }

    /// @notice Verifies that ERC-20 custody covers the tracked active liability.
    /// @dev Reverts when token custody is below the corresponding active raw-principal liability.
    function _assertSolvent(IERC20 token, uint256 requiredBalance) internal view {
        uint256 balance = token.balanceOf(address(this));
        if (balance < requiredBalance) {
            revert InsolventToken(address(token), balance, requiredBalance);
        }
    }
}
