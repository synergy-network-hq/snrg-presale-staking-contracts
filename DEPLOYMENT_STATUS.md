# Presale Staking v0.3 Deployment Status

## Current state

The release contains the hardened Base/Ethereum staking contracts, conventional two-of-three EIP-712 verifier boundary, deterministic deployment scripts, mandatory fork-source tests, production CI gates, and the frozen `LegacyRewardClaimV1` future-Mainnet import format.

No Base or Ethereum mainnet transaction has been broadcast from this build environment.

## Why mainnet broadcast is intentionally blocked

The supplied artifacts do not contain the production authorities or configuration required to safely and truthfully execute a mainnet deployment. The deployment scripts therefore remain in dry-run mode unless `BROADCAST=true` is explicitly supplied in an authorized execution environment.

Production values are supplied only at deployment time and must never be committed:

- approved governance Safe address;
- authorized Base/Ethereum deployment signer or HSM/keystore access;
- production Base RPC URL and BaseScan API key;
- production Ethereum RPC URL and Etherscan API key;
- enrollment opening and closing timestamps;
- production reward-voucher metadata base URI;
- three independent attestor identities and encrypted keystores;
- mTLS CA/server/client material and production service host placement.

The canonical four source contracts and representative fork fixtures have been resolved and the actual stake entrypoints pass on Base/Ethereum forks. Conventional EIP-712 attestation tests and durable relayer recovery tests pass. This file is updated during broadcast with addresses, transactions, verification status, and remaining Safe actions.

Known public integration references are pre-populated only where independently identified from Synergy source/configuration; secret material is never embedded.

## Release rule

Do not deploy stale `build/` or `out/` bytecode from the v0.2 archive. Production bytecode must be rebuilt by the pinned CI gate using Solidity 0.8.36, OpenZeppelin 5.6.1, forge-std v1.16.2, and Foundry v1.7.1, then fork-tested against all four real stake sources before broadcast.
