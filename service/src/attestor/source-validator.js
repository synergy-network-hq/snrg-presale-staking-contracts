import { Interface, JsonRpcProvider, getAddress } from 'ethers';
import { BASE_CHAIN_ID, ETHEREUM_CHAIN_ID, BASE_STAKING_ABI } from '../shared/abis.js';
import { ACTION, buildAttestation, sameAttestation, sameCommitment } from '../shared/codec.js';

const iface = new Interface(BASE_STAKING_ABI);

export class AttestorSourceValidator {
  constructor({ rpcUrl, stakingAddress, deployBlock }) {
    this.provider = new JsonRpcProvider(rpcUrl, Number(BASE_CHAIN_ID));
    this.stakingAddress = getAddress(stakingAddress);
    this.deployBlock = Number(deployBlock);
  }

  async finalizedHeadNumber() {
    const raw = await this.provider.send('eth_getBlockByNumber', ['finalized', false]);
    if (!raw?.number || !raw?.hash) throw new Error('Base RPC has no finalized head');
    return Number(BigInt(raw.number));
  }

  async loadCanonicalLog(locator) {
    const finalizedHead = await this.finalizedHeadNumber();
    const blockNumber = Number(locator.sourceBlockNumber);
    if (!Number.isSafeInteger(blockNumber) || blockNumber < this.deployBlock) {
      throw new Error('source block predates staking deployment');
    }
    if (blockNumber > finalizedHead) throw new Error('source event is not finalized');

    const block = await this.provider.getBlock(blockNumber);
    if (!block?.hash || block.hash.toLowerCase() !== String(locator.sourceBlockHash).toLowerCase()) {
      throw new Error('source block is no longer canonical');
    }
    if (String(block.timestamp) !== String(locator.sourceBlockTimestamp)) {
      throw new Error('source block timestamp mismatch');
    }

    const receipt = await this.provider.getTransactionReceipt(locator.sourceTxHash);
    if (!receipt || receipt.blockHash.toLowerCase() !== block.hash.toLowerCase()) {
      throw new Error('source transaction receipt mismatch');
    }
    const log = receipt.logs.find(entry => Number(entry.index) === Number(locator.sourceLogIndex));
    if (!log || getAddress(log.address) !== this.stakingAddress) throw new Error('canonical source log not found');
    const parsed = iface.parseLog(log);
    if (!parsed) throw new Error('source log is not a supported staking event');
    return parsed;
  }

  commitmentFromOpen(parsed) {
    if (parsed.name !== 'RewardCommitmentOpened') throw new Error('open locator is not RewardCommitmentOpened');
    const event = parsed.args;
    if (BigInt(event.destinationChainId) !== ETHEREUM_CHAIN_ID) throw new Error('invalid reward destination');
    return {
      rewardId: event.rewardId,
      sourceChainId: String(BASE_CHAIN_ID),
      sourceStakingContract: this.stakingAddress,
      sourcePositionId: event.positionId.toString(),
      beneficiary: event.beneficiary,
      stakeSource: Number(event.source),
      sourceAsset: event.sourceAsset,
      sourceTokenId: event.sourceTokenId.toString(),
      allocationId: event.allocationId,
      principalNwei: event.principalNwei.toString(),
      rewardNwei: event.rewardNwei.toString(),
      rewardBps: Number(event.rewardBps),
      startedAt: event.startedAt.toString(),
      maturesAt: event.maturesAt.toString(),
    };
  }

  async validate(request, expectedEpoch) {
    if (request.version !== 1) throw new Error('unsupported attestation request version');
    if (Number(request.attestation.attestationEpoch) !== Number(expectedEpoch)) throw new Error('wrong attestor epoch');
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (BigInt(request.attestation.expiry) <= now) throw new Error('attestation request expired');

    const canonicalOpen = this.commitmentFromOpen(await this.loadCanonicalLog(request.openLocator));
    if (!sameCommitment(canonicalOpen, request.commitment)) throw new Error('commitment differs from finalized Base event');

    const actionEvent = await this.loadCanonicalLog(request.actionLocator);
    if (request.action === ACTION.REGISTER) {
      if (actionEvent.name !== 'RewardCommitmentOpened') throw new Error('register requires RewardCommitmentOpened');
      if (
        String(request.actionLocator.sourceTxHash).toLowerCase() !== String(request.openLocator.sourceTxHash).toLowerCase()
        || String(request.actionLocator.sourceLogIndex) !== String(request.openLocator.sourceLogIndex)
      ) throw new Error('register action locator must equal open locator');
    } else if (request.action === ACTION.ISSUE) {
      if (actionEvent.name !== 'RewardSettlementAuthorized') throw new Error('issue requires RewardSettlementAuthorized');
      this.assertTerminalEvent(actionEvent.args, canonicalOpen);
    } else if (request.action === ACTION.CANCEL) {
      if (actionEvent.name !== 'RewardCommitmentCancelled') throw new Error('cancel requires RewardCommitmentCancelled');
      this.assertTerminalEvent(actionEvent.args, canonicalOpen);
      if (Number(request.reason) <= 0 || Number(actionEvent.args.reason) !== Number(request.reason)) {
        throw new Error('cancellation reason mismatch');
      }
    } else {
      throw new Error('unknown staking action');
    }

    const rebuilt = buildAttestation({
      action: request.action,
      commitment: canonicalOpen,
      reason: request.reason,
      locator: request.actionLocator,
      epochId: expectedEpoch,
      expiry: request.attestation.expiry,
    });
    if (!sameAttestation(rebuilt, request.attestation)) throw new Error('attestation fields differ from canonical event');
    return rebuilt;
  }

  assertTerminalEvent(event, commitment) {
    if (
      event.rewardId.toLowerCase() !== commitment.rewardId.toLowerCase()
      || event.positionId.toString() !== commitment.sourcePositionId
      || event.beneficiary.toLowerCase() !== commitment.beneficiary.toLowerCase()
      || event.rewardNwei.toString() !== commitment.rewardNwei
    ) throw new Error('terminal reward event differs from opening commitment');
  }
}
