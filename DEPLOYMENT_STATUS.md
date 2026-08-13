# Presale Staking v0.3 Deployment Status

## Current state

The release contains the hardened Base/Ethereum staking contracts, conventional two-of-three EIP-712 verifier boundary, deterministic deployment scripts, mandatory fork-source tests, production CI gates, and the frozen `LegacyRewardClaimV1` future-Mainnet import format.

The eight production contracts were deployed and exact-match verified from release commit
`bfbdf432fbacbdd6570bc546250a3da0990ea5b9`. The deployment addresses,
creation transactions, runtime bytecode hashes, ABIs, and explorer links are recorded in
`deployments/mainnet/contracts.json`. Safe Transaction Builder batches for the remaining
governance activation are recorded in `deployments/mainnet/safe-base-8453.json` and
`deployments/mainnet/safe-ethereum-1.json`.

## Live activation

Both governance Safe batches have been executed. The locked token is connected to the Base
staking contract, the required operational and reward-ledger roles are active, and attestor
epoch 1 has three authorized members with a two-of-three threshold. All three independent
attestors and the durable relay are enabled and active. The website preflight reports staking
enabled with transactions enabled and no readiness reasons.

The first live Base position was opened in transaction
`0x6188b564fb301ded5a1d009720cbb4a2c93f80d21d5f2de8323af0d9f81e376f`.
Its 200 SNRG reward commitment was registered on Ethereum in transaction
`0xb00716e66524b30512c50b90ede3b9c5c8768f155ccb49548f4f61b6866cace5`.
The gateway marks source event
`0x8de1da16aad4f09f9661237adba274eb1467c5e46547588df0d49122c6c6075d`
consumed, and replay returns `SourceEventAlreadyConsumed`. The reward remains pending until
the selected fixed term matures and the owner settles the position.

Secret production values remain outside the repository:

- production Base RPC URL and BaseScan API key;
- production Ethereum RPC URL and Etherscan API key;
- three independent attestor identities and encrypted keystores;
- mTLS CA/server/client material and production service host placement.

The canonical four source contracts and representative fork fixtures have been resolved and the actual stake entrypoints pass on Base/Ethereum forks. Conventional EIP-712 attestation tests and durable relayer recovery tests pass. This file is updated during broadcast with addresses, transactions, verification status, and remaining Safe actions.

Known public integration references are pre-populated only where independently identified from Synergy source/configuration; secret material is never embedded.

## Release rule

Do not deploy stale `build/` or `out/` bytecode from the v0.2 archive. Production bytecode must be rebuilt by the pinned CI gate using Solidity 0.8.36, OpenZeppelin 5.6.1, forge-std v1.16.2, and Foundry v1.7.1, then fork-tested against all four real stake sources before broadcast.
