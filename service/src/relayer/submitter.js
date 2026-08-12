import { Contract, Interface, JsonRpcProvider, NonceManager } from 'ethers';
import { REWARD_GATEWAY_ABI, REWARD_VOUCHER_EVENTS_ABI } from '../shared/abis.js';
import { ACTION, attestationTuple, commitmentTuple } from '../shared/codec.js';

const rewardInterface = new Interface(REWARD_VOUCHER_EVENTS_ABI);

export class EthereumGatewaySubmitter {
  constructor({ rpcUrl, signer, gatewayAddress, confirmations = 2 }) {
    this.provider = new JsonRpcProvider(rpcUrl, 1);
    this.wallet = new NonceManager(signer.connect(this.provider));
    this.gateway = new Contract(gatewayAddress, REWARD_GATEWAY_ABI, this.wallet);
    this.confirmations = confirmations;
  }

  async alreadyConsumed(sourceEventId) {
    return this.gateway.consumedSourceEvents(sourceEventId);
  }

  async submit({ action, commitment, reason, attestation, signatures, onSubmitted }) {
    const canonicalCommitment = commitmentTuple(commitment);
    const canonicalAttestation = attestationTuple(attestation);
    let transaction;
    if (action === ACTION.REGISTER) {
      transaction = await this.gateway.registerPendingReward(canonicalCommitment, canonicalAttestation, signatures);
    } else if (action === ACTION.ISSUE) {
      transaction = await this.gateway.issueRewardVoucher(canonicalCommitment, canonicalAttestation, signatures);
    } else if (action === ACTION.CANCEL) {
      transaction = await this.gateway.cancelPendingReward(canonicalCommitment, Number(reason), canonicalAttestation, signatures);
    } else {
      throw new Error(`unknown staking action ${action}`);
    }
    onSubmitted?.(transaction.hash);
    const receipt = await transaction.wait(this.confirmations);
    if (!receipt || receipt.status !== 1) throw new Error(`Ethereum transaction ${transaction.hash} failed`);
    let rewardTokenId = null;
    if (action === ACTION.ISSUE) {
      for (const log of receipt.logs) {
        try {
          const parsed = rewardInterface.parseLog(log);
          if (parsed?.name === 'RewardVoucherIssued') rewardTokenId = parsed.args.tokenId.toString();
        } catch { /* unrelated receipt log */ }
      }
    }
    return { hash: receipt.hash, rewardTokenId };
  }
}
