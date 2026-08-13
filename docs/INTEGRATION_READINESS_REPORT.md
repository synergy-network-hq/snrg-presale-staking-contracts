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

The eight contracts were deployed and exact-match verified on BaseScan or Etherscan. The
authoritative machine-readable record is `deployments/mainnet/contracts.json`; individual
ABI files are in `deployments/mainnet/abis/`.

Both governance Safe batches have been executed:

- `deployments/mainnet/safe-base-8453.json`
- `deployments/mainnet/safe-ethereum-1.json`

The attestor identities, CA-signed mTLS certificates, firewall restrictions, service units,
and durable-relay account exist outside the repository. The three attestors and relay are
enabled and active, with the relay continuously checking the active epoch and live quorum.

The first production Base stake is position 1 from transaction
`0x6188b564fb301ded5a1d009720cbb4a2c93f80d21d5f2de8323af0d9f81e376f`.
The reward registration transaction is
`0xb00716e66524b30512c50b90ede3b9c5c8768f155ccb49548f4f61b6866cace5`.
The Ethereum ledger records the reward as pending, and the source event is consumed exactly
once. Reward voucher issuance becomes available only after the selected 90-day term matures
and the owner settles the position; no administrator or relay can bypass that economic rule.
