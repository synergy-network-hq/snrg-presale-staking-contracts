import { Interface, JsonRpcProvider } from 'ethers';
import { BASE_CHAIN_ID, ETHEREUM_CHAIN_ID, BASE_STAKING_ABI } from '../shared/abis.js';
import { ACTION, buildAttestation, sourceEventId } from '../shared/codec.js';

const iface = new Interface(BASE_STAKING_ABI);
const EVENT_TOPICS = [
  iface.getEvent('RewardCommitmentOpened').topicHash,
  iface.getEvent('RewardSettlementAuthorized').topicHash,
  iface.getEvent('RewardCommitmentCancelled').topicHash,
];

export class BaseStakingWatcher {
  constructor({ rpcUrl, stakingAddress, startBlock, batchSize, store }) {
    this.provider = new JsonRpcProvider(rpcUrl, Number(BASE_CHAIN_ID));
    this.stakingAddress = stakingAddress;
    this.startBlock = Number(startBlock);
    this.batchSize = Number(batchSize || 1500);
    this.store = store;
    this.blockCache = new Map();
  }

  async finalizedHead() {
    const raw = await this.provider.send('eth_getBlockByNumber', ['finalized', false]);
    if (!raw || !raw.number || !raw.hash) throw new Error('Base RPC did not return a finalized block');
    return { number: Number(BigInt(raw.number)), hash: raw.hash, timestamp: Number(BigInt(raw.timestamp)) };
  }

  async verifyCheckpoint(checkpoint) {
    if (!checkpoint.finalized_block || !checkpoint.finalized_hash) return;
    const block = await this.provider.getBlock(checkpoint.finalized_block);
    if (!block || block.hash.toLowerCase() !== checkpoint.finalized_hash.toLowerCase()) {
      throw new Error(`FINALIZED_REORG_DETECTED at Base block ${checkpoint.finalized_block}`);
    }
  }

  async scanOnce() {
    const head = await this.finalizedHead();
    const checkpoint = this.store.getCheckpoint(BASE_CHAIN_ID);
    await this.verifyCheckpoint(checkpoint);

    let from = checkpoint.last_scanned_block > 0 ? checkpoint.last_scanned_block + 1 : this.startBlock;
    if (from > head.number) {
      this.store.setCheckpoint(BASE_CHAIN_ID, checkpoint.last_scanned_block, head.number, head.hash);
      return 0;
    }

    let discovered = 0;
    while (from <= head.number) {
      const to = Math.min(head.number, from + this.batchSize - 1);
      const logs = await this.provider.getLogs({
        address: this.stakingAddress,
        topics: [EVENT_TOPICS],
        fromBlock: from,
        toBlock: to,
      });
      logs.sort((a, b) => a.blockNumber === b.blockNumber ? a.index - b.index : a.blockNumber - b.blockNumber);
      for (const log of logs) discovered += await this.processLog(log) ? 1 : 0;
      this.store.setCheckpoint(BASE_CHAIN_ID, to, head.number, head.hash);
      from = to + 1;
    }
    return discovered;
  }

  async blockFor(log) {
    if (!this.blockCache.has(log.blockNumber)) this.blockCache.set(log.blockNumber, await this.provider.getBlock(log.blockNumber));
    const block = this.blockCache.get(log.blockNumber);
    if (!block || !block.hash) throw new Error(`Missing Base block ${log.blockNumber}`);
    return block;
  }

  locator(log, block) {
    return {
      sourceBlockNumber: String(log.blockNumber),
      sourceBlockTimestamp: String(block.timestamp),
      sourceLogIndex: String(log.index),
      sourceBlockHash: block.hash,
      sourceTxHash: log.transactionHash,
    };
  }

  async processLog(log, enqueue = true) {
    const parsed = iface.parseLog(log);
    if (!parsed) return false;
    const block = await this.blockFor(log);
    const locator = this.locator(log, block);

    if (parsed.name === 'RewardCommitmentOpened') {
      const a = parsed.args;
      if (BigInt(a.destinationChainId) !== ETHEREUM_CHAIN_ID) throw new Error('RewardCommitmentOpened destination is not Ethereum mainnet');
      const commitment = {
        rewardId: a.rewardId,
        sourceChainId: String(BASE_CHAIN_ID),
        sourceStakingContract: this.stakingAddress,
        sourcePositionId: a.positionId.toString(),
        beneficiary: a.beneficiary,
        stakeSource: Number(a.source),
        sourceAsset: a.sourceAsset,
        sourceTokenId: a.sourceTokenId.toString(),
        allocationId: a.allocationId,
        principalNwei: a.principalNwei.toString(),
        rewardNwei: a.rewardNwei.toString(),
        rewardBps: Number(a.rewardBps),
        startedAt: a.startedAt.toString(),
        maturesAt: a.maturesAt.toString(),
      };
      this.store.putCommitment(commitment, locator);
      if (!enqueue) return true;
      const attestation = buildAttestation({
        action: ACTION.REGISTER, commitment, reason: null, locator, epochId: 1, expiry: 1,
      });
      return this.store.recordSourceEvent({
        sourceEventId: sourceEventId(attestation),
        chainId: String(BASE_CHAIN_ID), eventName: parsed.name, action: ACTION.REGISTER,
        rewardId: commitment.rewardId, commitment, openLocator: locator, locator, reason: null,
      }) !== null;
    }

    const rewardId = parsed.args.rewardId;
    let stored = this.store.getCommitment(rewardId);
    if (!stored) stored = await this.backfillCommitment(rewardId, log.blockNumber);
    if (!stored) throw new Error(`No RewardCommitmentOpened found for ${rewardId}`);
    const c = stored.commitment;

    if (parsed.name === 'RewardSettlementAuthorized') {
      if (String(parsed.args.positionId) !== String(c.sourcePositionId) || parsed.args.beneficiary.toLowerCase() !== c.beneficiary.toLowerCase() || String(parsed.args.rewardNwei) !== String(c.rewardNwei)) {
        throw new Error(`Settlement event does not match stored commitment ${rewardId}`);
      }
      const attestation = buildAttestation({
        action: ACTION.ISSUE, commitment: c, reason: null, locator, epochId: 1, expiry: 1,
      });
      return this.store.recordSourceEvent({
        sourceEventId: sourceEventId(attestation),
        chainId: String(BASE_CHAIN_ID), eventName: parsed.name, action: ACTION.ISSUE,
        rewardId, commitment: c, openLocator: stored.openLocator, locator, reason: null,
      }) !== null;
    }

    if (parsed.name === 'RewardCommitmentCancelled') {
      if (String(parsed.args.positionId) !== String(c.sourcePositionId) || parsed.args.beneficiary.toLowerCase() !== c.beneficiary.toLowerCase() || String(parsed.args.rewardNwei) !== String(c.rewardNwei)) {
        throw new Error(`Cancellation event does not match stored commitment ${rewardId}`);
      }
      const attestation = buildAttestation({
        action: ACTION.CANCEL, commitment: c, reason: Number(parsed.args.reason), locator, epochId: 1, expiry: 1,
      });
      return this.store.recordSourceEvent({
        sourceEventId: sourceEventId(attestation),
        chainId: String(BASE_CHAIN_ID), eventName: parsed.name, action: ACTION.CANCEL,
        rewardId, commitment: c, openLocator: stored.openLocator, locator, reason: Number(parsed.args.reason),
      }) !== null;
    }
    return false;
  }

  async backfillCommitment(rewardId, beforeBlock) {
    const openTopic = iface.getEvent('RewardCommitmentOpened').topicHash;
    const logs = await this.provider.getLogs({
      address: this.stakingAddress,
      topics: [openTopic, rewardId],
      fromBlock: this.startBlock,
      toBlock: beforeBlock,
    });
    if (logs.length !== 1) throw new Error(`Expected exactly one open event for ${rewardId}; found ${logs.length}`);
    await this.processLog(logs[0], false);
    return this.store.getCommitment(rewardId);
  }
}
