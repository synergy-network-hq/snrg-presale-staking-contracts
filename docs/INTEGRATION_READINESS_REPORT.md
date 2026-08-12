# Conventional staking integration execution record

The active program uses conventional EVM security: three independent EIP-712 secp256k1 attestors with a Safe-managed two-of-three threshold. Aegis, ML-DSA, PQC, and zero-knowledge proof work are outside this bonus program.

## Proven locally and on forks

- Clean pinned build succeeds and all deployed bytecode is below the EIP-170 limit.
- Unit and hardening tests cover signature threshold, signer authorization/disablement, field substitution, expiry, replay, gateway-only issuance, and one-time issuance.
- Base fork tests execute `approve -> stake` for unlocked and locked SNRG and stake a real SAFT voucher entitlement.
- The locked token test executes its real Safe-only one-time `setStaking(address)` integration before the staking transfer.
- Ethereum fork tests stake a real presale allocation voucher after granting the exact reward-ledger roles.
- Node 22 service tests cover the three canonical Base events, EIP-712 codec parity, persistent duplicate rejection, interrupted processing recovery, and submitted-transaction recovery.

## Deployment record

Addresses, transaction hashes, blocks, bytecode hashes, explorer links, role receipts, service endpoints, and smoke-test evidence are written here immediately after mainnet execution. Human Safe signatures are tracked as exact calldata batches rather than represented as completed until executed.
