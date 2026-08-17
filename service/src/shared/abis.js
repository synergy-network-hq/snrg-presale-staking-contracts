export const BASE_CHAIN_ID = 8453n;
export const ETHEREUM_CHAIN_ID = 1n;

export const BASE_STAKING_ABI = [
  'event RewardCommitmentOpened(bytes32 indexed rewardId,uint256 indexed positionId,address indexed beneficiary,uint256 destinationChainId,uint8 source,address sourceAsset,uint256 sourceTokenId,bytes32 allocationId,uint256 principalNwei,uint256 rewardNwei,uint16 rewardBps,uint64 startedAt,uint64 maturesAt)',
  'event RewardSettlementAuthorized(bytes32 indexed rewardId,uint256 indexed positionId,address indexed beneficiary,uint256 rewardNwei,uint64 settledAt)',
  'event RewardCommitmentCancelled(bytes32 indexed rewardId,uint256 indexed positionId,address indexed beneficiary,uint256 rewardNwei,uint8 reason,uint64 cancelledAt)'
];

export const REWARD_COMMITMENT_TUPLE = 'tuple(bytes32 rewardId,uint256 sourceChainId,address sourceStakingContract,uint256 sourcePositionId,address beneficiary,uint8 stakeSource,address sourceAsset,uint256 sourceTokenId,bytes32 allocationId,uint256 principalNwei,uint256 rewardNwei,uint16 rewardBps,uint64 startedAt,uint64 maturesAt)';
export const FACT_ATTESTATION_TUPLE = 'tuple(bytes32 intentId,bytes32 umaId,uint256 sourceChainId,uint256 destinationChainId,bytes32 commitmentRef,bytes32 scopeDigest,uint256 replayNonce,uint64 expiry,uint64 witnessSetEpochId,uint64 aegisKeyVersion)';
export const PROOF_ENVELOPE_TUPLE = 'tuple(uint64 sourceBlockNumber,uint64 sourceBlockTimestamp,uint64 sourceLogIndex,bytes32 sourceBlockHash,bytes32 sourceTxHash,uint64 attestedAt,uint8 pqcAlgorithmId,bytes aegisProof)';
export const WITNESS_SIGNATURE_TUPLE = 'tuple(bytes32 witnessId,bytes publicKey,bytes signature,bytes32[] merkleProof)';

export const REWARD_GATEWAY_ABI = [
  `function registerPendingReward(${REWARD_COMMITMENT_TUPLE} commitment,${FACT_ATTESTATION_TUPLE} attestation,bytes proof)`,
  `function issueRewardVoucher(${REWARD_COMMITMENT_TUPLE} commitment,${FACT_ATTESTATION_TUPLE} attestation,bytes proof) returns (uint256 tokenId)`,
  `function cancelPendingReward(${REWARD_COMMITMENT_TUPLE} commitment,uint8 reason,${FACT_ATTESTATION_TUPLE} attestation,bytes proof)`,
  'function consumedAttestations(bytes32 attestationId) view returns (bool)',
  'function sxcpVerifier() view returns (address)',
  'event SXCPRewardFactConsumed(bytes32 indexed attestationId,bytes32 indexed rewardId,bytes32 indexed action)'
];

export const SXCP_STAKING_VERIFIER_ABI = [
  'function proofVerifier() view returns (address)',
  'function sourceStakingContract() view returns (address)'
];

export const AEGIS_THRESHOLD_PROOF_VERIFIER_ABI = [
  'function mldsaVerifier() view returns (address)'
];
