# LegacyRewardClaimV1 - future Mainnet import boundary

The immutable Ethereum `SynergyStakingRewardVoucher` contract is the authoritative pre-Mainnet history. A future Synergy Mainnet importer must derive each claim from finalized Ethereum state and the `RewardVoucherIssued` receipt, without requiring a pre-existing Ethereum PQ binding.

## Canonical identity and fields

The economic identity is `RewardCommitment.rewardId`. A valid import record binds:

- Ethereum chain ID `1`;
- the production reward-voucher address and issued token ID;
- every field of the stored `RewardCommitment`;
- beneficiary and reward amount;
- finalized issuance block hash, transaction hash, and log index;
- voucher state `ISSUED` (`2` in `SynergyStakingRewardVoucher.RewardState`);
- the Base source event and conventional EIP-712 attestation provenance when the source chain is Base.

All serialization uses `abi.encode`, never packed encoding. The importer must verify the Ethereum checkpoint, stored record, event receipt, reward ID, token ID, beneficiary, amount, and state agree, then prevent importing the same `rewardId` twice.

## Mainnet claim

Pre-Mainnet redemption remains disabled. After Mainnet exists, the claimant performs recipient/key binding as the normal first native claim step inside the Synergy security domain. That later Mainnet authorization does not alter the frozen Base or Ethereum staking history.
