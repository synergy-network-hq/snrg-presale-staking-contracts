export const BASE_CHAIN_ID = 8453n;
export const ETHEREUM_CHAIN_ID = 1n;

export const BASE_STAKING_ABI = [
  'event RewardCommitmentOpened(bytes32 indexed rewardId,uint256 indexed positionId,address indexed beneficiary,uint256 destinationChainId,uint8 source,address sourceAsset,uint256 sourceTokenId,bytes32 allocationId,uint256 principalNwei,uint256 rewardNwei,uint16 rewardBps,uint64 startedAt,uint64 maturesAt)',
  'event RewardSettlementAuthorized(bytes32 indexed rewardId,uint256 indexed positionId,address indexed beneficiary,uint256 rewardNwei,uint64 settledAt)',
  'event RewardCommitmentCancelled(bytes32 indexed rewardId,uint256 indexed positionId,address indexed beneficiary,uint256 rewardNwei,uint8 reason,uint64 cancelledAt)',
];

export const REWARD_COMMITMENT_TUPLE = 'tuple(bytes32 rewardId,uint256 sourceChainId,address sourceStakingContract,uint256 sourcePositionId,address beneficiary,uint8 stakeSource,address sourceAsset,uint256 sourceTokenId,bytes32 allocationId,uint256 principalNwei,uint256 rewardNwei,uint16 rewardBps,uint64 startedAt,uint64 maturesAt)';
export const STAKING_ATTESTATION_TUPLE = 'tuple(uint256 sourceChainId,uint256 destinationChainId,address sourceStakingContract,bytes32 sourceTxHash,uint64 sourceBlockNumber,bytes32 sourceBlockHash,uint64 sourceLogIndex,address staker,address beneficiary,uint8 stakeSourceType,address sourceAsset,uint256 sourceTokenId,bytes32 allocationId,uint256 sourcePositionId,uint256 principalNwei,uint256 rewardNwei,uint16 rewardBps,uint64 startedAt,uint64 maturesAt,bytes32 rewardId,uint8 action,uint8 cancellationReason,uint64 attestationEpoch,uint64 expiry)';

export const REWARD_GATEWAY_ABI = [
  `function registerPendingReward(${REWARD_COMMITMENT_TUPLE} commitment,${STAKING_ATTESTATION_TUPLE} attestation,bytes[] signatures)`,
  `function issueRewardVoucher(${REWARD_COMMITMENT_TUPLE} commitment,${STAKING_ATTESTATION_TUPLE} attestation,bytes[] signatures) returns (uint256 tokenId)`,
  `function cancelPendingReward(${REWARD_COMMITMENT_TUPLE} commitment,uint8 reason,${STAKING_ATTESTATION_TUPLE} attestation,bytes[] signatures)`,
  'function consumedSourceEvents(bytes32 sourceEventId) view returns (bool)',
  'event BaseStakingAttestationConsumed(bytes32 indexed sourceEventId,bytes32 indexed rewardId,uint8 action)',
];

export const ATTESTOR_REGISTRY_ABI = [
  'function epoch(uint64 epochId) view returns (tuple(uint16 threshold,uint16 attestorCount,bool active))',
  'function isAttestor(uint64 epochId,address account) view returns (bool)',
];

export const REWARD_VOUCHER_EVENTS_ABI = [
  'event RewardVoucherIssued(bytes32 indexed rewardId,uint256 indexed tokenId,address indexed beneficiary,uint256 rewardNwei)',
];
