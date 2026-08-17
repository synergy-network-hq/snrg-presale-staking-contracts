import { AbiCoder, Interface, getAddress, hexlify, keccak256, toUtf8Bytes } from 'ethers';
import {
  BASE_CHAIN_ID,
  ETHEREUM_CHAIN_ID,
  BASE_STAKING_ABI,
  REWARD_COMMITMENT_TUPLE,
  FACT_ATTESTATION_TUPLE,
  PROOF_ENVELOPE_TUPLE,
  WITNESS_SIGNATURE_TUPLE,
} from './abis.js';

const coder = AbiCoder.defaultAbiCoder();
export const baseInterface = new Interface(BASE_STAKING_ABI);
export const ACTION = Object.freeze({ REGISTER: 'REGISTER', ISSUE: 'ISSUE', CANCEL: 'CANCEL' });
export const ACTION_REGISTER_PENDING = keccak256(toUtf8Bytes('SYNERGY_STAKING_REGISTER_PENDING_V1'));
export const ACTION_ISSUE_REWARD = keccak256(toUtf8Bytes('SYNERGY_STAKING_ISSUE_REWARD_V1'));
export const ACTION_CANCEL_PENDING = keccak256(toUtf8Bytes('SYNERGY_STAKING_CANCEL_PENDING_V1'));

export const FACT_TYPEHASH = keccak256(toUtf8Bytes('SYNERGY_SXCP_STAKING_FACT_V1(bytes32 intentId,bytes32 umaId,uint256 sourceChainId,uint256 destinationChainId,bytes32 commitmentRef,bytes32 scopeDigest,uint256 replayNonce,uint64 expiry,uint64 witnessSetEpochId,uint64 aegisKeyVersion)'));
export const UMA_TYPEHASH = keccak256(toUtf8Bytes('SYNERGY_STAKING_UMA_V1(uint256 sourceChainId,uint64 sourceBlockNumber,bytes32 sourceBlockHash)'));
export const COMMITMENT_REF_TYPEHASH = keccak256(toUtf8Bytes('SYNERGY_STAKING_SOURCE_EVENT_V1(uint256 sourceChainId,address sourceStakingContract,uint64 sourceBlockNumber,bytes32 sourceBlockHash,bytes32 sourceTxHash,uint64 sourceLogIndex)'));
export const INTENT_TYPEHASH = keccak256(toUtf8Bytes('SYNERGY_STAKING_INTENT_V1(uint256 sourceChainId,uint256 destinationChainId,address sourceStakingContract,bytes32 commitmentRef,bytes32 scopeDigest)'));
export const REPLAY_TYPEHASH = keccak256(toUtf8Bytes('SYNERGY_STAKING_REPLAY_V1(bytes32 intentId,bytes32 umaId,bytes32 commitmentRef,bytes32 scopeDigest)'));
export const PROOF_TYPEHASH = keccak256(toUtf8Bytes('SYNERGY_STAKING_AEGIS_PROOF_V1(bytes32 factDigest,uint64 sourceBlockNumber,uint64 sourceBlockTimestamp,uint64 sourceLogIndex,bytes32 sourceBlockHash,bytes32 sourceTxHash,uint64 attestedAt,uint8 pqcAlgorithmId)'));
export const WITNESS_LEAF_TYPEHASH = keccak256(toUtf8Bytes('SYNERGY_AEGIS_STAKING_WITNESS_V1(bytes32 witnessId,uint8 algorithmId,bytes32 publicKeyHash,uint64 aegisKeyVersion)'));

export function commitmentTuple(c) {
  return [c.rewardId, BigInt(c.sourceChainId), getAddress(c.sourceStakingContract), BigInt(c.sourcePositionId), getAddress(c.beneficiary), Number(c.stakeSource), getAddress(c.sourceAsset), BigInt(c.sourceTokenId), c.allocationId, BigInt(c.principalNwei), BigInt(c.rewardNwei), Number(c.rewardBps), BigInt(c.startedAt), BigInt(c.maturesAt)];
}

export function attestationTuple(a) {
  return [a.intentId, a.umaId, BigInt(a.sourceChainId), BigInt(a.destinationChainId), a.commitmentRef, a.scopeDigest, BigInt(a.replayNonce), BigInt(a.expiry), BigInt(a.witnessSetEpochId), BigInt(a.aegisKeyVersion)];
}

export function scopeDigest(action, commitment, commitmentRef, reason = null) {
  const tuple = commitmentTuple(commitment);
  if (action === ACTION.REGISTER) return keccak256(coder.encode(['bytes32', REWARD_COMMITMENT_TUPLE, 'bytes32'], [ACTION_REGISTER_PENDING, tuple, commitmentRef]));
  if (action === ACTION.ISSUE) return keccak256(coder.encode(['bytes32', REWARD_COMMITMENT_TUPLE, 'bytes32'], [ACTION_ISSUE_REWARD, tuple, commitmentRef]));
  if (action === ACTION.CANCEL) {
    if (reason === null || Number(reason) === 0) throw new Error('cancel reason required');
    return keccak256(coder.encode(['bytes32', REWARD_COMMITMENT_TUPLE, 'uint8', 'bytes32'], [ACTION_CANCEL_PENDING, tuple, Number(reason), commitmentRef]));
  }
  throw new Error(`unknown action ${action}`);
}

export function deriveUmaId(locator) {
  return keccak256(coder.encode(['bytes32', 'uint256', 'uint64', 'bytes32'], [UMA_TYPEHASH, BASE_CHAIN_ID, BigInt(locator.sourceBlockNumber), locator.sourceBlockHash]));
}

export function deriveCommitmentRef(sourceStakingContract, locator) {
  return keccak256(coder.encode(['bytes32', 'uint256', 'address', 'uint64', 'bytes32', 'bytes32', 'uint64'], [COMMITMENT_REF_TYPEHASH, BASE_CHAIN_ID, getAddress(sourceStakingContract), BigInt(locator.sourceBlockNumber), locator.sourceBlockHash, locator.sourceTxHash, BigInt(locator.sourceLogIndex)]));
}

export function deriveIntentId(sourceStakingContract, commitmentRef, digest) {
  return keccak256(coder.encode(['bytes32', 'uint256', 'uint256', 'address', 'bytes32', 'bytes32'], [INTENT_TYPEHASH, BASE_CHAIN_ID, ETHEREUM_CHAIN_ID, getAddress(sourceStakingContract), commitmentRef, digest]));
}

export function deriveReplayNonce(intentId, umaId, commitmentRef, digest) {
  return BigInt(keccak256(coder.encode(['bytes32', 'bytes32', 'bytes32', 'bytes32', 'bytes32'], [REPLAY_TYPEHASH, intentId, umaId, commitmentRef, digest])));
}

export function buildAttestation({ action, commitment, reason, sourceStakingContract, locator, expiry, epochId, keyVersion }) {
  const commitmentRef = deriveCommitmentRef(sourceStakingContract, locator);
  const boundScope = scopeDigest(action, commitment, commitmentRef, reason);
  const umaId = deriveUmaId(locator);
  const intentId = deriveIntentId(sourceStakingContract, commitmentRef, boundScope);
  return {
    intentId,
    umaId,
    sourceChainId: BASE_CHAIN_ID,
    destinationChainId: ETHEREUM_CHAIN_ID,
    commitmentRef,
    scopeDigest: boundScope,
    replayNonce: deriveReplayNonce(intentId, umaId, commitmentRef, boundScope),
    expiry: BigInt(expiry),
    witnessSetEpochId: BigInt(epochId),
    aegisKeyVersion: BigInt(keyVersion),
  };
}

export function attestationDigest(attestation) {
  return keccak256(coder.encode(['bytes32', 'bytes32', 'bytes32', 'uint256', 'uint256', 'bytes32', 'bytes32', 'uint256', 'uint64', 'uint64', 'uint64'], [FACT_TYPEHASH, ...attestationTuple(attestation)]));
}

export function attestationId(attestation) {
  return keccak256(coder.encode(['bytes32', 'bytes32', 'uint256', 'uint256', 'bytes32', 'bytes32', 'uint256', 'uint64', 'uint64', 'uint64'], attestationTuple(attestation)));
}

export function proofDigest(attestation, locator, attestedAt, algorithmId = 1) {
  return keccak256(coder.encode(['bytes32', 'bytes32', 'uint64', 'uint64', 'uint64', 'bytes32', 'bytes32', 'uint64', 'uint8'], [PROOF_TYPEHASH, attestationDigest(attestation), BigInt(locator.sourceBlockNumber), BigInt(locator.sourceBlockTimestamp), BigInt(locator.sourceLogIndex), locator.sourceBlockHash, locator.sourceTxHash, BigInt(attestedAt), algorithmId]));
}

/** The only digest Aegis witnesses sign. It binds every fact field and Base finality locator. */
export function boundStatement(attestation, locator, attestedAt, algorithmId = 1) {
  return Object.freeze({
    version: 1,
    algorithm: 'ML-DSA-65',
    factDigest: attestationDigest(attestation),
    statementDigest: proofDigest(attestation, locator, attestedAt, algorithmId),
    sourceChainId: BASE_CHAIN_ID.toString(),
    destinationChainId: ETHEREUM_CHAIN_ID.toString(),
    locator: Object.freeze({ ...locator }),
  });
}

export function encodeProofEnvelope(locator, attestedAt, aegisProof, algorithmId = 1) {
  return coder.encode([PROOF_ENVELOPE_TUPLE], [[BigInt(locator.sourceBlockNumber), BigInt(locator.sourceBlockTimestamp), BigInt(locator.sourceLogIndex), locator.sourceBlockHash, locator.sourceTxHash, BigInt(attestedAt), algorithmId, aegisProof]]);
}

export function encodeWitnessProofBundle(signatures) {
  const ordered = [...signatures].sort((a, b) => BigInt(a.witnessId) < BigInt(b.witnessId) ? -1 : 1);
  const tuples = ordered.map(s => [s.witnessId, hexlify(Buffer.from(s.publicKeyBase64, 'base64')), hexlify(Buffer.from(s.signatureBase64, 'base64')), s.merkleProof]);
  return coder.encode(['uint8', `${WITNESS_SIGNATURE_TUPLE}[]`], [1, tuples]);
}

export function jsonStringify(value) {
  return JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v);
}

export function sameCommitment(a, b) {
  const normalize = value => commitmentTuple(value).map(v => typeof v === 'bigint' ? v.toString() : String(v).toLowerCase());
  return jsonStringify(normalize(a)) === jsonStringify(normalize(b));
}
