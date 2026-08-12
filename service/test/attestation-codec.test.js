import test from 'node:test';
import assert from 'node:assert/strict';
import { TypedDataEncoder, Wallet, verifyTypedData } from 'ethers';
import {
  ACTION,
  STAKING_ATTESTATION_TYPES,
  buildAttestation,
  eip712Domain,
  sourceEventId,
} from '../src/shared/codec.js';

const commitment = {
  rewardId: `0x${'aa'.repeat(32)}`, sourceChainId: '8453',
  sourceStakingContract: '0x000000000000000000000000000000000000b453', sourcePositionId: '8',
  beneficiary: '0x000000000000000000000000000000000000beef', stakeSource: 1,
  sourceAsset: '0x0000000000000000000000000000000000001234', sourceTokenId: '9',
  allocationId: `0x${'bb'.repeat(32)}`, principalNwei: '1000000000', rewardNwei: '40000000',
  rewardBps: 400, startedAt: '1700000000', maturesAt: '1707776000',
};
const locator = {
  sourceBlockNumber: '100', sourceBlockHash: `0x${'11'.repeat(32)}`, sourceLogIndex: '7',
  sourceTxHash: `0x${'22'.repeat(32)}`, sourceBlockTimestamp: '1700000000',
};
const verifier = '0x0000000000000000000000000000000000009999';

test('EIP-712 codec yields a recoverable signer and deterministic source event ID', async () => {
  const attestation = buildAttestation({
    action: ACTION.REGISTER, commitment, reason: null, locator, epochId: 1, expiry: 1800000000,
  });
  const wallet = Wallet.createRandom();
  const domain = eip712Domain(verifier);
  const signature = await wallet.signTypedData(domain, STAKING_ATTESTATION_TYPES, attestation);
  assert.equal(verifyTypedData(domain, STAKING_ATTESTATION_TYPES, attestation, signature), wallet.address);
  assert.match(TypedDataEncoder.hash(domain, STAKING_ATTESTATION_TYPES, attestation), /^0x[0-9a-f]{64}$/);
  assert.equal(sourceEventId(attestation), sourceEventId({ ...attestation, expiry: 1800001000n }));
});

test('terminal actions bind action, cancellation reason, and exact source locator', () => {
  const issue = buildAttestation({ action: ACTION.ISSUE, commitment, reason: null, locator, epochId: 4, expiry: 1800000000 });
  const cancel = buildAttestation({ action: ACTION.CANCEL, commitment, reason: 2, locator, epochId: 4, expiry: 1800000000 });
  assert.equal(issue.action, 1);
  assert.equal(issue.cancellationReason, 0);
  assert.equal(cancel.action, 2);
  assert.equal(cancel.cancellationReason, 2);
  assert.notEqual(TypedDataEncoder.hash(eip712Domain(verifier), STAKING_ATTESTATION_TYPES, issue), TypedDataEncoder.hash(eip712Domain(verifier), STAKING_ATTESTATION_TYPES, cancel));
});
