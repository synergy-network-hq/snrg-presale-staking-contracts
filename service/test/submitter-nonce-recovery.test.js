import test from 'node:test';
import assert from 'node:assert/strict';
import { ACTION } from '../src/shared/codec.js';
import { EthereumGatewaySubmitter } from '../src/relayer/submitter.js';

const commitment = {
  rewardId: `0x${'11'.repeat(32)}`,
  sourceChainId: 8453n,
  sourceStakingContract: '0x0000000000000000000000000000000000000001',
  sourcePositionId: 1n,
  beneficiary: '0x0000000000000000000000000000000000000002',
  stakeSource: 1,
  sourceAsset: '0x0000000000000000000000000000000000000003',
  sourceTokenId: 0n,
  allocationId: `0x${'00'.repeat(32)}`,
  principalNwei: 5_000_000_000_000n,
  rewardNwei: 200_000_000_000n,
  rewardBps: 400,
  startedAt: 1n,
  maturesAt: 2n,
};

const attestation = {
  sourceChainId: 8453n,
  destinationChainId: 1n,
  sourceStakingContract: '0x0000000000000000000000000000000000000001',
  sourceTxHash: `0x${'22'.repeat(32)}`,
  sourceBlockNumber: 1n,
  sourceBlockHash: `0x${'33'.repeat(32)}`,
  sourceLogIndex: 0n,
  staker: '0x0000000000000000000000000000000000000002',
  beneficiary: '0x0000000000000000000000000000000000000002',
  stakeSourceType: 1,
  sourceAsset: '0x0000000000000000000000000000000000000003',
  sourceTokenId: 0n,
  allocationId: `0x${'00'.repeat(32)}`,
  sourcePositionId: 1n,
  principalNwei: 5_000_000_000_000n,
  rewardNwei: 200_000_000_000n,
  rewardBps: 400,
  startedAt: 1n,
  maturesAt: 2n,
  rewardId: `0x${'11'.repeat(32)}`,
  action: 0,
  cancellationReason: 0,
  attestationEpoch: 1n,
  expiry: 10n,
};

test('failed broadcast resets the managed nonce before retry', async () => {
  const submitter = Object.create(EthereumGatewaySubmitter.prototype);
  let resets = 0;
  submitter.wallet = { reset: () => { resets += 1; } };
  submitter.gateway = {
    registerPendingReward: async () => { throw new Error('insufficient funds'); },
  };

  await assert.rejects(
    submitter.submit({ action: ACTION.REGISTER, commitment, attestation, signatures: [] }),
    /insufficient funds/,
  );
  assert.equal(resets, 1);
});
