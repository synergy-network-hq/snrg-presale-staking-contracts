# SNRG Presale Staking v0.3 — production release candidate

This package is the Base/Ethereum staking and conventional threshold-attestation integration for the four presale stake sources:

1. Base unlocked SNRG
2. Base locked / Early Supporter SNRG
3. Base SAFT voucher entitlement
4. Ethereum presale claim-voucher entitlement

## Economic terms

- 90 days: 4% fixed total reward
- 180 days: 6% fixed total reward
- 270 days: 8% fixed total reward
- 365 days: 10% fixed total reward
- early exit returns 100% of ERC-20 principal or releases 100% of virtual entitlement and forfeits 100% of that position's reward
- reward accounting uses 9-decimal SNRG nwei

## Pre-Mainnet invariant

Ethereum reward vouchers are immutable historical entitlement records. `redeemForSynergyMainnet()` always reverts before Mainnet exists. Future Synergy Mainnet imports `LegacyRewardClaimV1`, performs PQ recipient binding as the normal first claim step, and atomically consumes `rewardId` exactly once when native SNRG is credited.

## Toolchain

See `TOOLCHAIN.lock`. Production uses Foundry v1.7.1, Solidity 0.8.36, forge-std v1.16.2 at `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b`, and OpenZeppelin v5.6.1 at `5fd1781b1454fd1ef8e722282f86f9293cacf256`.

## Required configuration

Copy `config/production.env.example` outside the repository and populate it from the production secrets/configuration system. Do not commit private keys. The Base SAFT voucher address and representative fork-test fixture IDs are mandatory and must come from the deployed source contract, not from a guess.

## Build

```bash
rm -rf lib
mkdir -p lib
git clone https://github.com/OpenZeppelin/openzeppelin-contracts.git lib/openzeppelin-contracts
git -C lib/openzeppelin-contracts checkout 5fd1781b1454fd1ef8e722282f86f9293cacf256
git clone https://github.com/foundry-rs/forge-std.git lib/forge-std
git -C lib/forge-std checkout bf647bd6046f2f7da30d0c2bf435e5c76a780c1b
forge build --sizes
forge test --match-path 'test/ProductionHardening.t.sol' -vvv
```

The GitHub production gate additionally requires both live mainnet RPCs and all real source fixtures. Missing fork inputs fail the job.

## Dry run

A dry run prints immutable constructor configuration and does not intentionally broadcast:

```bash
set -a
. /secure/path/presale-staking.production.env
set +a
export BROADCAST=false
forge script script/DeployBaseProduction.s.sol:DeployBaseProduction --rpc-url "$BASE_RPC_URL" -vvvv
forge script script/DeployEthereumProduction.s.sol:DeployEthereumProduction --rpc-url "$ETHEREUM_RPC_URL" -vvvv
```

Review all values and archive the output. Never change `BROADCAST` until `docs/PRODUCTION_GATES.md` is fully green.

## Production broadcast

Use a dedicated deployer whose only purpose is paying deployment gas. Governance and operational roles belong to the configured Safe/independent operators. Supply signing through an approved keystore/HSM workflow; do not put private keys in the repository or shell history.

```bash
export BROADCAST=true
forge script script/DeployBaseProduction.s.sol:DeployBaseProduction \
  --rpc-url "$BASE_RPC_URL" --broadcast --verify --etherscan-api-key "$BASESCAN_API_KEY" -vvvv

# Set BASE_STAKING_ADDRESS and BASE_STAKING_DEPLOY_BLOCK from the finalized Base receipt before Ethereum deployment.

forge script script/DeployEthereumProduction.s.sol:DeployEthereumProduction \
  --rpc-url "$ETHEREUM_RPC_URL" --broadcast --verify --etherscan-api-key "$ETHERSCAN_API_KEY" -vvvv
```

After Ethereum deployment, submit every emitted `grantRole` and `configureEpoch` payload through `GOVERNANCE_SAFE`; verify receipts and roles before starting the attestor and relayer services.

## Service separation

- Three independent attestors: separate hosts and secp256k1 identities, mTLS, and independent finalized Base-event verification.
- On-chain registry: Safe-controlled epoch membership with a two-of-three signature threshold.
- Relayer: separate gas-only wallet; no governance or reward-issuance role.
- State: durable SQLite storage with restart recovery and deterministic source-event replay protection.

See `docs/PRODUCTION_GATES.md` and `docs/LEGACY_REWARD_CLAIM_V1.md`.
