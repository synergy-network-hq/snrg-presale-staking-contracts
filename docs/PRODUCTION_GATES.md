# Presale staking production gates

These are executable release gates for the conventional Base-to-Ethereum bonus program.

## Build and source tests

- Foundry `1.7.1`, Solidity `0.8.36`, OpenZeppelin `5.6.1`, forge-std `1.16.2`, EVM target Cancun, optimizer 200, via-IR.
- `forge clean && forge build --sizes` passes from source.
- Unit/hardening and two-of-three EIP-712 tests pass.
- Base and Ethereum fork tests exercise the actual four production sources through their real stake entrypoints.
- Node 22 `npm ci`, syntax, service recovery tests, and dependency audit pass using the committed lock.

## Conventional threshold attestation

- Exactly three independently hosted secp256k1 attestors.
- Safe-owned attestor registry, active epoch, threshold two of three.
- Each attestor independently re-reads the exact finalized Base log and block hash before signing the EIP-712 statement.
- Signatures are unique, authorized, sorted, unexpired, and bind every source locator and economic field.
- The gas-only relayer owns no governance or reward issuer role.
- Durable storage persists source event, attestation, signatures, destination transaction, and reward token; restart and retry cannot issue twice.

## Governance and operation

- `GOVERNANCE_SAFE` is the existing production Safe.
- Reward registrar/issuer authority is granted only to the Ethereum voucher staking contract and validated Base gateway.
- The locked Early Supporter token's one-time `setStaking(address)` call is executed through the Safe.
- Role and epoch configuration is verified on-chain before enrollment is exposed.
- Attestor and relayer services run as enabled systemd units with encrypted keys, mTLS, health checks, durable state, restart policy, and backups.

## Deployment evidence

- Dry-run constructor values and Safe calls are archived before broadcast.
- Mainnet receipts record chain, address, transaction, block, bytecode hashes, source commit, compiler settings, and constructor arguments.
- Every deployed contract is source-verified on the appropriate explorer.
- Unauthorized issuance and replay fail in deployed-state smoke checks.

## Future Mainnet boundary

- Ethereum reward vouchers remain immutable historical records.
- Pre-Mainnet redemption is disabled.
- Future Synergy Mainnet imports the frozen `LegacyRewardClaimV1` history and performs its own recipient binding at first native claim.
