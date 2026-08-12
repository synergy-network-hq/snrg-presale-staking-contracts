// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {RewardTypes} from "../common/RewardTypes.sol";
import {StakingTerms} from "../common/StakingTerms.sol";

/// @title Synergy Staking Reward Claim Voucher
/// @author Synergy Network
/// @notice Ethereum-mainnet soulbound claim voucher and canonical accounting ledger for presale staking rewards.
/// @dev The contract does not custody or draw from a reward pool and does not enforce a budget cap. It dynamically
///      tracks pending, issued, outstanding, redeemed, cancelled, early-exit-forfeited, and invalidated reward totals.
///      DEFAULT_ADMIN_ROLE uses OpenZeppelin's delayed two-step transfer rules. Reward NFTs are non-transferable.
contract SynergyStakingRewardVoucher is
    ERC721,
    AccessControlDefaultAdminRules,
    Pausable,
    ReentrancyGuard
{
    using Strings for uint256;

    /// @notice Role authorized to register or cancel pending reward liabilities.
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    /// @notice Role authorized to issue matured reward NFTs.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    /// @notice Role authorized to pause and unpause reward registration, issuance, and redemption.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role authorized to update the base token URI.
    bytes32 public constant METADATA_ROLE = keccak256("METADATA_ROLE");

    uint48 private constant _DEFAULT_ADMIN_TRANSFER_DELAY = 2 days;

    // Canonical ERC-165 interface IDs. Keeping these local avoids importing interfaces solely
    // for type(...).interfaceId and keeps the deployed API identical.
    bytes4 private constant _INTERFACE_ID_ERC165 = 0x01ffc9a7;
    bytes4 private constant _INTERFACE_ID_ERC721 = 0x80ac58cd;
    bytes4 private constant _INTERFACE_ID_ERC721_METADATA = 0x5b5e139f;
    bytes4 private constant _INTERFACE_ID_ACCESS_CONTROL = 0x7965db0b;
    bytes4 private constant _INTERFACE_ID_DEFAULT_ADMIN_RULES = 0x31498786;

    /// @notice Lifecycle state of a staking reward commitment.
    enum RewardState {
        NONE,
        PENDING,
        ISSUED,
        REDEEMED,
        CANCELLED
    }

    /// @notice Full stored state for one canonical reward ID.
    struct RewardRecord {
        RewardTypes.RewardCommitment commitment;
        RewardState state;
        RewardTypes.CancellationReason cancellationReason;
        uint256 tokenId;
        uint64 registeredAt;
        uint64 issuedAt;
        uint64 redeemedAt;
        uint64 cancelledAt;
        bytes32 mainnetRecipient;
    }

    /// @notice Aggregate reward accounting for either the whole system or one source staking contract.
    struct Accounting {
        uint256 pendingNwei;
        uint256 issuedLifetimeNwei;
        uint256 outstandingVoucherNwei;
        uint256 redeemedNwei;
        uint256 cancelledNwei;
        uint256 earlyExitForfeitedNwei;
        uint256 invalidatedNwei;
        uint256 lifetimeCommittedNwei;
        uint256 pendingCount;
        uint256 issuedCount;
        uint256 redeemedCount;
        uint256 cancelledCount;
        uint256 earlyExitCount;
        uint256 invalidatedCount;
    }

    uint256 private _nextTokenId = 1;
    string private _baseTokenURI;

    mapping(bytes32 rewardId => RewardRecord record) private _rewards;

    /// @notice Maps an issued reward voucher token ID to its canonical reward ID.
    mapping(uint256 tokenId => bytes32 rewardId) public rewardIdByTokenId;

    /// @notice Maps a canonical reward ID to its issued reward voucher token ID; zero means not issued.
    mapping(bytes32 rewardId => uint256 tokenId) public tokenIdByRewardId;

    mapping(bytes32 sourceKey => Accounting accounting) private _sourceAccounting;

    /// @notice Live total of promised rewards for active/unissued staking positions.
    uint256 public totalPendingStakeRewardsNwei;

    /// @notice Lifetime total of rewards converted into Ethereum staking reward vouchers.
    uint256 public totalIssuedStakeRewardsNwei;

    /// @notice Total reward amount represented by issued vouchers that have not yet been redeemed.
    uint256 public totalOutstandingRewardVouchersNwei;

    /// @notice Lifetime total of staking rewards redeemed toward Synergy Mainnet-beta.
    uint256 public totalRedeemedStakeRewardsNwei;

    /// @notice Lifetime total of pending rewards cancelled before NFT issuance.
    uint256 public totalCancelledStakeRewardsNwei;

    /// @notice Lifetime total of rewards forfeited by voluntary early unstaking.
    uint256 public totalEarlyExitForfeitedRewardsNwei;

    /// @notice Lifetime total of rewards invalidated because the source entitlement was consumed.
    uint256 public totalInvalidatedStakeRewardsNwei;

    /// @notice Lifetime total of all valid reward commitments ever registered or terminally tombstoned.
    uint256 public totalLifetimeCommittedStakeRewardsNwei;

    /// @notice Number of currently pending reward commitments.
    uint256 public totalPendingRewardCount;

    /// @notice Lifetime number of issued staking reward vouchers.
    uint256 public totalIssuedRewardVoucherCount;

    /// @notice Lifetime number of redeemed staking reward vouchers.
    uint256 public totalRedeemedRewardVoucherCount;

    /// @notice Lifetime number of cancelled reward commitments.
    uint256 public totalCancelledRewardCount;

    /// @notice Lifetime number of voluntary early-exit reward forfeitures.
    uint256 public totalEarlyExitCount;

    /// @notice Lifetime number of source-invalidated reward commitments.
    uint256 public totalInvalidatedRewardCount;

    /// @notice Reverts when a required address is zero.
    error ZeroAddress();
    /// @notice Reverts when constructor ETH is non-zero.
    error EtherNotAccepted();
    /// @notice Reverts when a reward commitment is malformed or economically inconsistent.
    error InvalidCommitment();
    /// @notice Reverts when a cancellation reason is NONE or otherwise unsupported.
    error InvalidCancellationReason();
    /// @notice Reverts when a repeated reward ID is supplied with different economic facts.
    error RewardCommitmentMismatch(bytes32 rewardId);
    /// @notice Reverts when a reward expected to be pending is in another state.
    error RewardNotPending(bytes32 rewardId);
    /// @notice Reverts when a reward expected to be issued is in another state.
    error RewardNotIssued(bytes32 rewardId);
    /// @notice Reverts when issuance is attempted before the stored maturity timestamp.
    error RewardNotMatured(bytes32 rewardId);
    /// @notice Reverts when issuance is attempted for a cancelled reward.
    error RewardCancelled(bytes32 rewardId);
    /// @notice Reverts when a reward cannot legally transition to CANCELLED.
    error RewardCannotBeCancelled(bytes32 rewardId);
    /// @notice Reverts when a duplicate cancellation uses a different terminal reason.
    error CancellationReasonMismatch(bytes32 rewardId);
    /// @notice Reverts when a redemption caller is not the current voucher owner.
    error NotVoucherOwner();
    /// @notice Reverts when any ERC-721 approval or wallet-to-wallet transfer is attempted.
    error SoulboundTransferBlocked();
    /// @notice Reverts when the supplied Synergy Mainnet-beta recipient identifier is zero.
    error InvalidMainnetRecipient();
    /// @notice Reverts because native Synergy redemption is intentionally disabled before Mainnet exists.
    error MainnetRedemptionNotEnabled();

    /// @notice Emitted once when the reward voucher collection and admin are configured.
    event RewardVoucherConfigured(address indexed admin, string baseTokenURI);

    /// @notice Emitted when a new reward liability is registered as pending.
    event PendingRewardRegistered(
        bytes32 indexed rewardId,
        uint256 indexed sourceChainId,
        address indexed beneficiary,
        address sourceStakingContract,
        uint256 sourcePositionId,
        uint256 principalNwei,
        uint256 rewardNwei,
        uint16 rewardBps,
        uint64 maturesAt
    );

    /// @notice Emitted when an identical late/duplicate reward registration is intentionally ignored.
    event RewardRegistrationIgnored(bytes32 indexed rewardId, RewardState existingState);

    /// @notice Emitted when an unissued reward is terminally cancelled.
    event PendingRewardCancelled(
        bytes32 indexed rewardId,
        uint256 rewardNwei,
        RewardTypes.CancellationReason reason,
        bool wasPending
    );

    /// @notice Emitted when an identical duplicate cancellation is intentionally ignored.
    event DuplicateCancellationIgnored(bytes32 indexed rewardId, RewardTypes.CancellationReason reason);

    /// @notice Emitted when a matured reward commitment is converted into a soulbound Ethereum NFT.
    event RewardVoucherIssued(
        bytes32 indexed rewardId,
        uint256 indexed tokenId,
        address indexed beneficiary,
        uint256 rewardNwei
    );

    /// @notice Emitted whenever the soulbound ERC-721 ownership state changes through mint or a future burn path.
    event SoulboundVoucherStateChanged(
        uint256 indexed tokenId,
        address indexed from,
        address indexed to
    );

    /// @notice Emitted when a duplicate issuance request resolves to an already issued voucher.
    event RewardIssuanceIgnored(bytes32 indexed rewardId, uint256 indexed tokenId, RewardState existingState);

    /// @notice Emitted when the voucher owner requests redemption toward Synergy Mainnet-beta.
    event RewardRedemptionRequested(
        bytes32 indexed rewardId,
        uint256 indexed tokenId,
        address indexed owner,
        bytes32 mainnetRecipient,
        uint256 rewardNwei
    );

    /// @notice Emitted when the collection metadata base URI changes.
    event BaseTokenURIUpdated(string newBaseTokenURI);

    /// @notice Emitted when the application pause state changes.
    event RewardVoucherPauseChanged(bool paused, address indexed account);

    /// @notice Emitted when a canonical reward commitment snapshot is persisted.
    event RewardCommitmentSnapshotStored(bytes32 indexed rewardId);

    /// @notice Emitted when lifetime committed-reward accounting increases.
    event LifetimeRewardAccountingUpdated(
        bytes32 indexed rewardId,
        uint256 globalLifetimeCommittedNwei,
        uint256 sourceLifetimeCommittedNwei
    );

    /// @notice Emitted when a reward leaves the pending-liability bucket.
    event PendingRewardAccountingUpdated(
        bytes32 indexed rewardId,
        uint256 globalPendingNwei,
        uint256 sourcePendingNwei
    );

    /// @notice Emitted when a reward enters a terminal cancellation bucket.
    event CancelledRewardAccountingUpdated(
        bytes32 indexed rewardId,
        RewardTypes.CancellationReason indexed reason,
        uint256 globalCancelledNwei,
        uint256 sourceCancelledNwei
    );

    /// @notice Restricts a function to the current owner of a reward voucher token.
    /// @param tokenId Reward voucher token ID.
    modifier onlyVoucherOwner(uint256 tokenId) {
        if (_ownerOf(tokenId) != msg.sender) revert NotVoucherOwner();
        _;
    }

    /// @notice Deploys the canonical Ethereum staking reward voucher and liability ledger.
    /// @dev The constructor grants no operational roles. The default admin should explicitly assign PAUSER_ROLE,
    ///      METADATA_ROLE, REGISTRAR_ROLE, and ISSUER_ROLE to dedicated production authorities/contracts.
    /// @param admin Initial delayed DEFAULT_ADMIN_ROLE holder.
    /// @param baseTokenURI_ Initial metadata base URI.
    constructor(address admin, string memory baseTokenURI_)
        payable
        ERC721("Synergy Staking Reward Claim Voucher", "SNRG-SR-CV")
        AccessControlDefaultAdminRules(_DEFAULT_ADMIN_TRANSFER_DELAY, admin)
    {
        if (msg.value != 0) revert EtherNotAccepted();
        if (admin == address(0)) revert ZeroAddress();

        _baseTokenURI = baseTokenURI_;

        emit RewardVoucherConfigured(admin, baseTokenURI_);
    }

    /// @notice Registers a reward promise when a staking position opens.
    /// @dev No budget cap is enforced. An identical late duplicate is an idempotent no-op.
    /// @param commitment Canonical staking reward commitment.
    function registerPendingReward(RewardTypes.RewardCommitment calldata commitment)
        external
        nonReentrant
        onlyRole(REGISTRAR_ROLE)
        whenNotPaused
    {
        _validateCommitment(commitment);

        RewardRecord storage record = _rewards[commitment.rewardId];
        if (record.state != RewardState.NONE) {
            _requireSameCommitment(record.commitment, commitment);
            emit RewardRegistrationIgnored(commitment.rewardId, record.state);
            return;
        }

        _registerPending(record, commitment);
    }

    /// @notice Permanently cancels an unissued reward, including a voluntary early unstake.
    /// @dev Cancellation intentionally remains callable while paused so principal exits can always void rewards.
    ///      A cancellation that arrives before registration creates a terminal tombstone against delayed replay.
    /// @param commitment Canonical staking reward commitment.
    /// @param reason Terminal cancellation reason.
    function cancelPendingReward(
        RewardTypes.RewardCommitment calldata commitment,
        RewardTypes.CancellationReason reason
    ) external nonReentrant onlyRole(REGISTRAR_ROLE) {
        _validateCommitment(commitment);
        if (reason == RewardTypes.CancellationReason.NONE) revert InvalidCancellationReason();

        RewardRecord storage record = _rewards[commitment.rewardId];

        if (record.state == RewardState.NONE) {
            _storeCommitment(record.commitment, commitment);
            record.state = RewardState.CANCELLED;
            record.cancellationReason = reason;
            record.cancelledAt = uint64(block.timestamp);

            _increaseLifetimeCommitted(commitment);
            _increaseCancelled(commitment, reason);

            emit PendingRewardCancelled(commitment.rewardId, commitment.rewardNwei, reason, false);
            return;
        }

        _requireSameCommitment(record.commitment, commitment);

        if (record.state == RewardState.CANCELLED) {
            if (record.cancellationReason != reason) {
                revert CancellationReasonMismatch(commitment.rewardId);
            }
            emit DuplicateCancellationIgnored(commitment.rewardId, reason);
            return;
        }

        if (record.state != RewardState.PENDING) revert RewardCannotBeCancelled(commitment.rewardId);

        record.state = RewardState.CANCELLED;
        record.cancellationReason = reason;
        record.cancelledAt = uint64(block.timestamp);

        _decreasePending(commitment);
        _increaseCancelled(commitment, reason);

        emit PendingRewardCancelled(commitment.rewardId, commitment.rewardNwei, reason, true);
    }

    /// @notice Converts a matured reward commitment into the Ethereum soulbound reward NFT.
    /// @dev If settlement arrives before pending registration, registration and issuance occur atomically.
    /// @param commitment Canonical staking reward commitment.
    /// @return tokenId Issued reward voucher token ID.
    function issueRewardVoucher(RewardTypes.RewardCommitment calldata commitment)
        external
        nonReentrant
        onlyRole(ISSUER_ROLE)
        whenNotPaused
        returns (uint256 tokenId)
    {
        _validateCommitment(commitment);
        RewardRecord storage record = _rewards[commitment.rewardId];

        if (record.state == RewardState.NONE) {
            _registerPending(record, commitment);
        } else {
            _requireSameCommitment(record.commitment, commitment);
        }

        if (record.state == RewardState.CANCELLED) revert RewardCancelled(commitment.rewardId);
        if (record.state == RewardState.ISSUED) {
            emit RewardIssuanceIgnored(commitment.rewardId, record.tokenId, record.state);
            return record.tokenId;
        }
        if (record.state == RewardState.REDEEMED) {
            emit RewardIssuanceIgnored(commitment.rewardId, record.tokenId, record.state);
            return record.tokenId;
        }
        if (record.state != RewardState.PENDING) revert RewardNotPending(commitment.rewardId);
        if (block.timestamp < record.commitment.maturesAt) revert RewardNotMatured(commitment.rewardId);

        tokenId = _nextTokenId;
        _nextTokenId = tokenId + 1;

        record.state = RewardState.ISSUED;
        record.tokenId = tokenId;
        record.issuedAt = uint64(block.timestamp);

        rewardIdByTokenId[tokenId] = commitment.rewardId;
        tokenIdByRewardId[commitment.rewardId] = tokenId;

        uint256 rewardAmountNwei = commitment.rewardNwei;
        _decreasePending(commitment);

        totalIssuedStakeRewardsNwei = totalIssuedStakeRewardsNwei + rewardAmountNwei;
        totalOutstandingRewardVouchersNwei = totalOutstandingRewardVouchersNwei + rewardAmountNwei;
        totalIssuedRewardVoucherCount = totalIssuedRewardVoucherCount + 1;

        Accounting storage accounting =
            _sourceAccounting[_sourceKey(commitment.sourceChainId, commitment.sourceStakingContract)];
        accounting.issuedLifetimeNwei = accounting.issuedLifetimeNwei + rewardAmountNwei;
        accounting.outstandingVoucherNwei = accounting.outstandingVoucherNwei + rewardAmountNwei;
        accounting.issuedCount = accounting.issuedCount + 1;

        // Intentionally mint without the ERC721Receiver callback. All voucher/accounting state has already
        // been committed and reward vouchers are soulbound, so the protocol does not need a recipient callback.
        // Avoiding that external callback removes an unnecessary reentrancy surface from reward issuance.
        _update(commitment.beneficiary, tokenId, address(0));

        emit RewardVoucherIssued(commitment.rewardId, tokenId, commitment.beneficiary, rewardAmountNwei);
        return tokenId;
    }

    /// @notice Reserved ABI entry point for future Synergy Mainnet redemption compatibility.
    /// @dev PRE-MAINNET DEPLOYMENTS MUST NEVER use Ethereum ownership alone to select a Synergy recipient or mark
    ///      a reward redeemed. Future Mainnet imports the immutable issued record and performs PQ recipient binding
    ///      as the normal first claim step inside the Synergy security domain.
    function redeemForSynergyMainnet(uint256, bytes32) external pure {
        revert MainnetRedemptionNotEnabled();
    }

    /// @notice Returns the complete reward record for a canonical reward ID.
    /// @dev This is a read-only dashboard/audit helper and performs no state transition.
    /// @param rewardId Canonical reward ID.
    /// @return record Stored reward state and commitment.
    function rewardRecord(bytes32 rewardId) external view returns (RewardRecord memory record) {
        record = _rewards[rewardId];
        return record;
    }

    /// @notice Returns the complete reward record represented by an issued voucher token ID.
    /// @dev This resolves token ID to reward ID before returning the stored record.
    /// @param tokenId Reward voucher token ID.
    /// @return record Stored reward state and commitment.
    function voucherRecord(uint256 tokenId) external view returns (RewardRecord memory record) {
        record = _rewards[rewardIdByTokenId[tokenId]];
        return record;
    }

    /// @notice Returns accounting attributable to one source-chain staking contract.
    /// @dev Source accounting is keyed by canonical ABI-encoded chain ID plus staking-contract address.
    /// @param sourceChainId Source chain ID.
    /// @param sourceStakingContract Source staking contract.
    /// @return accounting Aggregated source accounting.
    function sourceAccounting(uint256 sourceChainId, address sourceStakingContract)
        external
        view
        returns (Accounting memory accounting)
    {
        accounting = _sourceAccounting[_sourceKey(sourceChainId, sourceStakingContract)];
        return accounting;
    }

    /// @notice Dashboard-friendly alias for the live pending staking reward total.
    /// @dev The authoritative counter is `totalPendingStakeRewardsNwei`.
    /// @return Current promised-but-unissued reward amount in canonical SNRG nwei.
    function totalPendingStakeRewards() external view returns (uint256) {
        return totalPendingStakeRewardsNwei;
    }

    /// @notice Returns all global reward-liability counters in one struct.
    /// @dev Values are reporting/accounting values; this contract does not enforce a reward pool cap.
    /// @return accounting Current and lifetime global accounting values.
    function globalAccounting() external view returns (Accounting memory accounting) {
        accounting.pendingNwei = totalPendingStakeRewardsNwei;
        accounting.issuedLifetimeNwei = totalIssuedStakeRewardsNwei;
        accounting.outstandingVoucherNwei = totalOutstandingRewardVouchersNwei;
        accounting.redeemedNwei = totalRedeemedStakeRewardsNwei;
        accounting.cancelledNwei = totalCancelledStakeRewardsNwei;
        accounting.earlyExitForfeitedNwei = totalEarlyExitForfeitedRewardsNwei;
        accounting.invalidatedNwei = totalInvalidatedStakeRewardsNwei;
        accounting.lifetimeCommittedNwei = totalLifetimeCommittedStakeRewardsNwei;
        accounting.pendingCount = totalPendingRewardCount;
        accounting.issuedCount = totalIssuedRewardVoucherCount;
        accounting.redeemedCount = totalRedeemedRewardVoucherCount;
        accounting.cancelledCount = totalCancelledRewardCount;
        accounting.earlyExitCount = totalEarlyExitCount;
        accounting.invalidatedCount = totalInvalidatedRewardCount;
        return accounting;
    }

    /// @notice Updates the collection metadata base URI.
    /// @dev An identical URI is ignored to avoid an unnecessary storage write.
    /// @param newBaseTokenURI New base URI used by tokenURI().
    function setBaseTokenURI(string calldata newBaseTokenURI) external nonReentrant onlyRole(METADATA_ROLE) {
        if (keccak256(bytes(_baseTokenURI)) == keccak256(bytes(newBaseTokenURI))) return;
        _baseTokenURI = newBaseTokenURI;
        emit BaseTokenURIUpdated(newBaseTokenURI);
    }

    /// @notice Pauses new registrations, issuance, and redemption; cancellation remains available.
    /// @dev Restricted to `PAUSER_ROLE`; inherited Pausable state and an application event are both updated.
    function pause() external nonReentrant onlyRole(PAUSER_ROLE) {
        _pause();
        emit RewardVoucherPauseChanged(true, msg.sender);
    }

    /// @notice Resumes normal reward registration, issuance, and redemption.
    /// @dev Restricted to `PAUSER_ROLE`.
    function unpause() external nonReentrant onlyRole(PAUSER_ROLE) {
        _unpause();
        emit RewardVoucherPauseChanged(false, msg.sender);
    }

    /// @inheritdoc ERC721
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (bytes(_baseTokenURI).length == 0) return "";
        return string.concat(_baseTokenURI, tokenId.toString());
    }

    /// @inheritdoc ERC721
    function approve(address, uint256) public pure override {
        revert SoulboundTransferBlocked();
    }

    /// @inheritdoc ERC721
    function setApprovalForAll(address, bool) public pure override {
        revert SoulboundTransferBlocked();
    }

    /// @inheritdoc ERC721
    /// @dev Blocks wallet-to-wallet transfers while preserving minting and any future internal burn path.
    /// @param to Destination address.
    /// @param tokenId Reward voucher token ID.
    /// @param auth Authorized caller used by ERC721 internals.
    /// @return from Previous token owner.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address from)
    {
        from = _ownerOf(tokenId);
        if (from != address(0)) {
            if (to != address(0)) revert SoulboundTransferBlocked();
        }
        address previousOwner = super._update(to, tokenId, auth);
        emit SoulboundVoucherStateChanged(tokenId, previousOwner, to);
        return previousOwner;
    }

    /// @inheritdoc ERC721
    /// @notice ERC-165 interface support for ERC-721 and delayed AccessControl APIs.
    /// @dev Explicit interface-ID checks avoid making a direct supportsInterface() call that some static analyzers
    ///      conservatively classify as potentially reverting.
    /// @param interfaceId ERC-165 interface identifier.
    /// @return True when the interface is implemented by this contract.
    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override(ERC721, AccessControlDefaultAdminRules)
        returns (bool)
    {
        if (interfaceId == _INTERFACE_ID_ERC165) return true;
        if (interfaceId == _INTERFACE_ID_ERC721) return true;
        if (interfaceId == _INTERFACE_ID_ERC721_METADATA) return true;
        if (interfaceId == _INTERFACE_ID_ACCESS_CONTROL) return true;
        if (interfaceId == _INTERFACE_ID_DEFAULT_ADMIN_RULES) return true;
        return false;
    }

    /// @notice Stores a previously unseen reward commitment as pending.
    /// @dev Stores a new reward commitment, increments pending accounting, and emits registration provenance.
    function _registerPending(
        RewardRecord storage record,
        RewardTypes.RewardCommitment calldata commitment
    ) internal {
        _storeCommitment(record.commitment, commitment);
        record.state = RewardState.PENDING;
        record.registeredAt = uint64(block.timestamp);

        totalPendingStakeRewardsNwei = totalPendingStakeRewardsNwei + commitment.rewardNwei;
        totalPendingRewardCount = totalPendingRewardCount + 1;
        _increaseLifetimeCommitted(commitment);

        Accounting storage accounting =
            _sourceAccounting[_sourceKey(commitment.sourceChainId, commitment.sourceStakingContract)];
        accounting.pendingNwei = accounting.pendingNwei + commitment.rewardNwei;
        accounting.pendingCount = accounting.pendingCount + 1;

        emit PendingRewardRegistered(
            commitment.rewardId,
            commitment.sourceChainId,
            commitment.beneficiary,
            commitment.sourceStakingContract,
            commitment.sourcePositionId,
            commitment.principalNwei,
            commitment.rewardNwei,
            commitment.rewardBps,
            commitment.maturesAt
        );
    }

    /// @notice Copies canonical reward commitment fields into persistent storage.
    /// @dev Copies calldata commitment fields individually into storage.
    function _storeCommitment(
        RewardTypes.RewardCommitment storage destination,
        RewardTypes.RewardCommitment calldata source
    ) internal {
        destination.rewardId = source.rewardId;
        destination.sourceChainId = source.sourceChainId;
        destination.sourceStakingContract = source.sourceStakingContract;
        destination.sourcePositionId = source.sourcePositionId;
        destination.beneficiary = source.beneficiary;
        destination.stakeSource = source.stakeSource;
        destination.sourceAsset = source.sourceAsset;
        destination.sourceTokenId = source.sourceTokenId;
        destination.allocationId = source.allocationId;
        destination.principalNwei = source.principalNwei;
        destination.rewardNwei = source.rewardNwei;
        destination.rewardBps = source.rewardBps;
        destination.startedAt = source.startedAt;
        destination.maturesAt = source.maturesAt;
        emit RewardCommitmentSnapshotStored(source.rewardId);
    }

    /// @notice Increases lifetime committed reward accounting.
    /// @dev Increases lifetime commitment accounting without affecting pending state.
    function _increaseLifetimeCommitted(RewardTypes.RewardCommitment calldata commitment) internal {
        totalLifetimeCommittedStakeRewardsNwei =
            totalLifetimeCommittedStakeRewardsNwei + commitment.rewardNwei;
        Accounting storage accounting =
            _sourceAccounting[_sourceKey(commitment.sourceChainId, commitment.sourceStakingContract)];
        accounting.lifetimeCommittedNwei = accounting.lifetimeCommittedNwei + commitment.rewardNwei;
        emit LifetimeRewardAccountingUpdated(
            commitment.rewardId,
            totalLifetimeCommittedStakeRewardsNwei,
            accounting.lifetimeCommittedNwei
        );
    }

    /// @notice Removes one commitment from live pending accounting.
    /// @dev Removes one commitment from live pending accounting.
    function _decreasePending(RewardTypes.RewardCommitment calldata commitment) internal {
        totalPendingStakeRewardsNwei = totalPendingStakeRewardsNwei - commitment.rewardNwei;
        totalPendingRewardCount = totalPendingRewardCount - 1;

        Accounting storage accounting =
            _sourceAccounting[_sourceKey(commitment.sourceChainId, commitment.sourceStakingContract)];
        accounting.pendingNwei = accounting.pendingNwei - commitment.rewardNwei;
        accounting.pendingCount = accounting.pendingCount - 1;
        emit PendingRewardAccountingUpdated(
            commitment.rewardId,
            totalPendingStakeRewardsNwei,
            accounting.pendingNwei
        );
    }

    /// @notice Increases terminal cancellation accounting.
    /// @dev Increases terminal cancellation accounting and its reason-specific subcategory.
    function _increaseCancelled(
        RewardTypes.RewardCommitment calldata commitment,
        RewardTypes.CancellationReason reason
    ) internal {
        totalCancelledStakeRewardsNwei = totalCancelledStakeRewardsNwei + commitment.rewardNwei;
        totalCancelledRewardCount = totalCancelledRewardCount + 1;

        Accounting storage accounting =
            _sourceAccounting[_sourceKey(commitment.sourceChainId, commitment.sourceStakingContract)];
        accounting.cancelledNwei = accounting.cancelledNwei + commitment.rewardNwei;
        accounting.cancelledCount = accounting.cancelledCount + 1;

        if (reason == RewardTypes.CancellationReason.EARLY_UNSTAKE) {
            totalEarlyExitForfeitedRewardsNwei =
                totalEarlyExitForfeitedRewardsNwei + commitment.rewardNwei;
            totalEarlyExitCount = totalEarlyExitCount + 1;
            accounting.earlyExitForfeitedNwei =
                accounting.earlyExitForfeitedNwei + commitment.rewardNwei;
            accounting.earlyExitCount = accounting.earlyExitCount + 1;
            emit CancelledRewardAccountingUpdated(
                commitment.rewardId, reason, totalCancelledStakeRewardsNwei, accounting.cancelledNwei
            );
            return;
        }

        if (reason == RewardTypes.CancellationReason.SOURCE_INVALIDATED) {
            totalInvalidatedStakeRewardsNwei = totalInvalidatedStakeRewardsNwei + commitment.rewardNwei;
            totalInvalidatedRewardCount = totalInvalidatedRewardCount + 1;
            accounting.invalidatedNwei = accounting.invalidatedNwei + commitment.rewardNwei;
            accounting.invalidatedCount = accounting.invalidatedCount + 1;
            emit CancelledRewardAccountingUpdated(
                commitment.rewardId, reason, totalCancelledStakeRewardsNwei, accounting.cancelledNwei
            );
            return;
        }

        revert InvalidCancellationReason();
    }

    /// @notice Verifies a duplicate reward fact matches the stored commitment exactly.
    /// @dev Verifies that a duplicate reward ID carries exactly the same immutable commitment fields.
    function _requireSameCommitment(
        RewardTypes.RewardCommitment storage stored,
        RewardTypes.RewardCommitment calldata supplied
    ) internal view {
        if (stored.rewardId != supplied.rewardId) revert RewardCommitmentMismatch(supplied.rewardId);
        if (stored.sourceChainId != supplied.sourceChainId) revert RewardCommitmentMismatch(supplied.rewardId);
        if (stored.sourceStakingContract != supplied.sourceStakingContract) {
            revert RewardCommitmentMismatch(supplied.rewardId);
        }
        if (stored.sourcePositionId != supplied.sourcePositionId) {
            revert RewardCommitmentMismatch(supplied.rewardId);
        }
        if (stored.beneficiary != supplied.beneficiary) revert RewardCommitmentMismatch(supplied.rewardId);
        if (stored.stakeSource != supplied.stakeSource) revert RewardCommitmentMismatch(supplied.rewardId);
        if (stored.sourceAsset != supplied.sourceAsset) revert RewardCommitmentMismatch(supplied.rewardId);
        if (stored.sourceTokenId != supplied.sourceTokenId) revert RewardCommitmentMismatch(supplied.rewardId);
        if (stored.allocationId != supplied.allocationId) revert RewardCommitmentMismatch(supplied.rewardId);
        if (stored.principalNwei != supplied.principalNwei) revert RewardCommitmentMismatch(supplied.rewardId);
        if (stored.rewardNwei != supplied.rewardNwei) revert RewardCommitmentMismatch(supplied.rewardId);
        if (stored.rewardBps != supplied.rewardBps) revert RewardCommitmentMismatch(supplied.rewardId);
        if (stored.startedAt != supplied.startedAt) revert RewardCommitmentMismatch(supplied.rewardId);
        if (stored.maturesAt != supplied.maturesAt) revert RewardCommitmentMismatch(supplied.rewardId);
    }

    /// @notice Validates reward provenance and fixed reward economics.
    /// @dev Validates reward provenance fields and recomputes the exact fixed reward from principal and bps.
    function _validateCommitment(RewardTypes.RewardCommitment calldata commitment) internal pure {
        if (commitment.rewardId == bytes32(0)) revert InvalidCommitment();
        if (commitment.sourceChainId == 0) revert InvalidCommitment();
        if (commitment.sourceStakingContract == address(0)) revert InvalidCommitment();
        if (commitment.sourcePositionId == 0) revert InvalidCommitment();
        if (commitment.beneficiary == address(0)) revert InvalidCommitment();
        if (commitment.sourceAsset == address(0)) revert InvalidCommitment();
        if (commitment.principalNwei == 0) revert InvalidCommitment();
        if (commitment.rewardNwei == 0) revert InvalidCommitment();
        if (commitment.startedAt == 0) revert InvalidCommitment();
        if (commitment.maturesAt <= commitment.startedAt) revert InvalidCommitment();
        if (!StakingTerms.isAllowedRewardBps(commitment.rewardBps)) revert InvalidCommitment();
        if (commitment.rewardNwei != StakingTerms.rewardForBps(commitment.principalNwei, commitment.rewardBps)) {
            revert InvalidCommitment();
        }
    }

    /// @notice Computes the accounting key for a source-chain staking application.
    /// @dev Uses canonical ABI encoding to derive a collision-resistant source key.
    function _sourceKey(uint256 sourceChainId, address sourceStakingContract)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(sourceChainId, sourceStakingContract));
    }
}
