import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { StakingRelayerStore } from '../src/relayer/store.js';

const locator = {
  sourceBlockNumber: '77', sourceBlockTimestamp: '1700000000', sourceLogIndex: '4',
  sourceBlockHash: `0x${'11'.repeat(32)}`,
  sourceTxHash: `0x${'22'.repeat(32)}`,
};
const sourceEventId = `0x${'33'.repeat(32)}`;
const commitment = {
  rewardId: `0x${'aa'.repeat(32)}`,
  sourceChainId: '8453', sourceStakingContract: '0x000000000000000000000000000000000000b453',
  sourcePositionId: '1', beneficiary: '0x000000000000000000000000000000000000beef', stakeSource: 0,
  sourceAsset: '0x0000000000000000000000000000000000001234', sourceTokenId: '0',
  allocationId: `0x${'00'.repeat(32)}`,
  principalNwei: '1000000000', rewardNwei: '40000000', rewardBps: 400,
  startedAt: '1700000000', maturesAt: '1707776000',
};

function sourceEvent() {
  return {
    sourceEventId,
    chainId: '8453', eventName: 'RewardCommitmentOpened', action: 'REGISTER',
    rewardId: commitment.rewardId, commitment, openLocator: locator, locator, reason: null,
  };
}

test('SQLite restart recovers processing work, preserves signed data, and deduplicates source event', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'staking-relayer-'));
  const databasePath = path.join(directory, 'relayer.sqlite');
  const first = new StakingRelayerStore(databasePath);
  first.initialize();
  first.putCommitment(commitment, locator);
  const id = first.recordSourceEvent(sourceEvent());
  first.saveAttestation(id, { expiry: '1800000000', rewardId: commitment.rewardId }, ['0x1234', '0x5678']);
  first.markProcessing(id);
  first.close();

  const second = new StakingRelayerStore(databasePath);
  second.initialize();
  second.recoverInterrupted();
  const [pending] = second.pendingEvents();
  assert.equal(pending.id, id);
  assert.match(pending.last_error, /Recovered after relayer restart/);
  assert.equal(pending.attestation.rewardId, commitment.rewardId);
  assert.deepEqual(pending.signatures, ['0x1234', '0x5678']);
  assert.equal(second.recordSourceEvent(sourceEvent()), null);
  second.close();
  fs.rmSync(directory, { recursive: true, force: true });
});

test('SQLite restart recovers submitted transaction without creating a duplicate event', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'staking-relayer-'));
  const databasePath = path.join(directory, 'relayer.sqlite');
  const first = new StakingRelayerStore(databasePath);
  first.initialize();
  const id = first.recordSourceEvent(sourceEvent());
  first.markSubmitted(id, `0x${'44'.repeat(32)}`);
  first.close();

  const second = new StakingRelayerStore(databasePath);
  second.initialize();
  second.recoverInterrupted();
  const [pending] = second.pendingEvents();
  assert.equal(pending.ethereum_tx_hash, `0x${'44'.repeat(32)}`);
  assert.equal(pending.status, 'retry');
  assert.equal(second.recordSourceEvent(sourceEvent()), null);
  second.close();
  fs.rmSync(directory, { recursive: true, force: true });
});
