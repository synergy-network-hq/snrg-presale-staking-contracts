import test from 'node:test';
import assert from 'node:assert/strict';
import { Interface } from 'ethers';
import { BASE_STAKING_ABI } from '../src/shared/abis.js';
import { AttestorSourceValidator } from '../src/attestor/source-validator.js';

const stakingAddress = '0x000000000000000000000000000000000000b453';
const beneficiary = '0x000000000000000000000000000000000000bEEF';
const sourceAsset = '0x0000000000000000000000000000000000001234';
const blockHash = `0x${'11'.repeat(32)}`;
const txHash = `0x${'22'.repeat(32)}`;
const rewardId = `0x${'33'.repeat(32)}`;
const iface = new Interface(BASE_STAKING_ABI);

function validatorWith({ finalizedBlock = 100, canonicalHash = blockHash } = {}) {
  const validator = new AttestorSourceValidator({
    rpcUrl: 'http://127.0.0.1:1', stakingAddress, deployBlock: 1,
  });
  const encoded = iface.encodeEventLog(iface.getEvent('RewardCommitmentOpened'), [
    rewardId, 7n, beneficiary, 1n, 0, sourceAsset, 0n, `0x${'00'.repeat(32)}`,
    1_000_000_000n, 40_000_000n, 400, 1_700_000_000, 1_707_776_000,
  ]);
  validator.provider = {
    send: async () => ({ number: `0x${finalizedBlock.toString(16)}`, hash: canonicalHash }),
    getBlock: async () => ({ hash: canonicalHash, timestamp: 1_700_000_000 }),
    getTransactionReceipt: async () => ({
      blockHash: canonicalHash,
      logs: [{ address: stakingAddress, index: 3, topics: encoded.topics, data: encoded.data }],
    }),
  };
  return validator;
}

const locator = {
  sourceBlockNumber: '100', sourceBlockTimestamp: '1700000000', sourceLogIndex: '3',
  sourceBlockHash: blockHash, sourceTxHash: txHash,
};

test('attestor rejects an event above the Base finalized head', async () => {
  await assert.rejects(
    validatorWith({ finalizedBlock: 99 }).loadCanonicalLog(locator),
    /source event is not finalized/,
  );
});

test('attestor rejects a source block that is no longer canonical', async () => {
  await assert.rejects(
    validatorWith({ canonicalHash: `0x${'44'.repeat(32)}` }).loadCanonicalLog(locator),
    /source block is no longer canonical/,
  );
});

test('attestor accepts the exact finalized canonical Base event', async () => {
  const parsed = await validatorWith().loadCanonicalLog(locator);
  assert.equal(parsed.name, 'RewardCommitmentOpened');
  assert.equal(parsed.args.rewardId, rewardId);
});
