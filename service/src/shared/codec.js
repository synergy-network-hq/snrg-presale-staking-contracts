import { AbiCoder, Interface, getAddress, keccak256, toUtf8Bytes } from 'ethers';
import { BASE_CHAIN_ID, ETHEREUM_CHAIN_ID, BASE_STAKING_ABI } from './abis.js';

const coder = AbiCoder.defaultAbiCoder();
export const baseInterface = new Interface(BASE_STAKING_ABI);
export const ACTION = Object.freeze({ REGISTER: 'REGISTER', ISSUE: 'ISSUE', CANCEL: 'CANCEL' });
export const ACTION_CODE = Object.freeze({ REGISTER: 0, ISSUE: 1, CANCEL: 2 });

export const EIP712_DOMAIN = Object.freeze({
  name: 'Synergy Presale Staking Attestation',
  version: '1',
});

export const STAKING_ATTESTATION_TYPES = Object.freeze({
  StakingAttestation: [
    { name: 'sourceChainId', type: 'uint256' },
    { name: 'destinationChainId', type: 'uint256' },
    { name: 'sourceStakingContract', type: 'address' },
    { name: 'sourceTxHash', type: 'bytes32' },
    { name: 'sourceBlockNumber', type: 'uint64' },
    { name: 'sourceBlockHash', type: 'bytes32' },
    { name: 'sourceLogIndex', type: 'uint64' },
    { name: 'staker', type: 'address' },
    { name: 'beneficiary', type: 'address' },
    { name: 'stakeSourceType', type: 'uint8' },
    { name: 'sourceAsset', type: 'address' },
    { name: 'sourceTokenId', type: 'uint256' },
    { name: 'allocationId', type: 'bytes32' },
    { name: 'sourcePositionId', type: 'uint256' },
    { name: 'principalNwei', type: 'uint256' },
    { name: 'rewardNwei', type: 'uint256' },
    { name: 'rewardBps', type: 'uint16' },
    { name: 'startedAt', type: 'uint64' },
    { name: 'maturesAt', type: 'uint64' },
    { name: 'rewardId', type: 'bytes32' },
    { name: 'action', type: 'uint8' },
    { name: 'cancellationReason', type: 'uint8' },
    { name: 'attestationEpoch', type: 'uint64' },
    { name: 'expiry', type: 'uint64' },
  ],
});

export const SOURCE_EVENT_TYPEHASH = keccak256(toUtf8Bytes(
  'SYNERGY_STAKING_SOURCE_EVENT_V1(uint256 sourceChainId,address sourceStakingContract,bytes32 sourceTxHash,uint64 sourceLogIndex)',
));

export function eip712Domain(verifierAddress) {
  return {
    ...EIP712_DOMAIN,
    chainId: ETHEREUM_CHAIN_ID,
    verifyingContract: getAddress(verifierAddress),
  };
}

export function commitmentTuple(c) {
  return [
    c.rewardId,
    BigInt(c.sourceChainId),
    getAddress(c.sourceStakingContract),
    BigInt(c.sourcePositionId),
    getAddress(c.beneficiary),
    Number(c.stakeSource),
    getAddress(c.sourceAsset),
    BigInt(c.sourceTokenId),
    c.allocationId,
    BigInt(c.principalNwei),
    BigInt(c.rewardNwei),
    Number(c.rewardBps),
    BigInt(c.startedAt),
    BigInt(c.maturesAt),
  ];
}

export function attestationTuple(a) {
  return [
    BigInt(a.sourceChainId),
    BigInt(a.destinationChainId),
    getAddress(a.sourceStakingContract),
    a.sourceTxHash,
    BigInt(a.sourceBlockNumber),
    a.sourceBlockHash,
    BigInt(a.sourceLogIndex),
    getAddress(a.staker),
    getAddress(a.beneficiary),
    Number(a.stakeSourceType),
    getAddress(a.sourceAsset),
    BigInt(a.sourceTokenId),
    a.allocationId,
    BigInt(a.sourcePositionId),
    BigInt(a.principalNwei),
    BigInt(a.rewardNwei),
    Number(a.rewardBps),
    BigInt(a.startedAt),
    BigInt(a.maturesAt),
    a.rewardId,
    Number(a.action),
    Number(a.cancellationReason),
    BigInt(a.attestationEpoch),
    BigInt(a.expiry),
  ];
}

export function buildAttestation({ action, commitment, reason, locator, epochId, expiry }) {
  if (!(action in ACTION_CODE)) throw new Error(`unknown staking action ${action}`);
  const cancellationReason = action === ACTION.CANCEL ? Number(reason) : 0;
  if (action === ACTION.CANCEL && (!Number.isInteger(cancellationReason) || cancellationReason <= 0)) {
    throw new Error('cancel reason required');
  }
  return {
    sourceChainId: BASE_CHAIN_ID,
    destinationChainId: ETHEREUM_CHAIN_ID,
    sourceStakingContract: getAddress(commitment.sourceStakingContract),
    sourceTxHash: locator.sourceTxHash,
    sourceBlockNumber: BigInt(locator.sourceBlockNumber),
    sourceBlockHash: locator.sourceBlockHash,
    sourceLogIndex: BigInt(locator.sourceLogIndex),
    staker: getAddress(commitment.beneficiary),
    beneficiary: getAddress(commitment.beneficiary),
    stakeSourceType: Number(commitment.stakeSource),
    sourceAsset: getAddress(commitment.sourceAsset),
    sourceTokenId: BigInt(commitment.sourceTokenId),
    allocationId: commitment.allocationId,
    sourcePositionId: BigInt(commitment.sourcePositionId),
    principalNwei: BigInt(commitment.principalNwei),
    rewardNwei: BigInt(commitment.rewardNwei),
    rewardBps: Number(commitment.rewardBps),
    startedAt: BigInt(commitment.startedAt),
    maturesAt: BigInt(commitment.maturesAt),
    rewardId: commitment.rewardId,
    action: ACTION_CODE[action],
    cancellationReason,
    attestationEpoch: BigInt(epochId),
    expiry: BigInt(expiry),
  };
}

export function sourceEventId(attestation) {
  return keccak256(coder.encode(
    ['bytes32', 'uint256', 'address', 'bytes32', 'uint64'],
    [
      SOURCE_EVENT_TYPEHASH,
      BigInt(attestation.sourceChainId),
      getAddress(attestation.sourceStakingContract),
      attestation.sourceTxHash,
      BigInt(attestation.sourceLogIndex),
    ],
  ));
}

export function jsonStringify(value) {
  return JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v);
}

export function sameCommitment(a, b) {
  const normalized = value => jsonStringify(commitmentTuple(value).map(v => (
    typeof v === 'bigint' ? v.toString() : String(v).toLowerCase()
  )));
  return normalized(a) === normalized(b);
}

export function sameAttestation(a, b) {
  const normalized = value => jsonStringify(attestationTuple(value).map(v => (
    typeof v === 'bigint' ? v.toString() : String(v).toLowerCase()
  )));
  return normalized(a) === normalized(b);
}
