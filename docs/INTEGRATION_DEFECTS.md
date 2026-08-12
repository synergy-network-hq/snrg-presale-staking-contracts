# v0.3 integration defects and non-economic repairs

## Scope

This record covers only the reproducible build and canonical-interface defects identified during local validation of the supplied v0.3 release candidate. It makes no change to staking economics, contract behavior, authority model, or deployment policy.

## Defect 1: EVM target incompatible with pinned OpenZeppelin

**Evidence.** The release pins Solidity `0.8.36` and OpenZeppelin Contracts `5.6.1` at `5fd1781b1454fd1ef8e722282f86f9293cacf256`. With the supplied `evm_version = "shanghai"`, the exact pinned build fails in OpenZeppelin `utils/Bytes.sol`: `mcopy` is available only for Cancun-compatible EVM targets.

**Repair.** `foundry.toml` and `TOOLCHAIN.lock` now pin `cancun`. This is required for the exact pinned OpenZeppelin release; it does not alter any staking-economic constant or application source logic.

## Defect 2: obsolete duplicate verifier interface types

**Evidence.** The supplied transitional implementation declared duplicate verifier interfaces in two paths, making otherwise identical Solidity structs incompatible. The active bonus-program architecture subsequently standardized on the single conventional `IStakingAttestationVerifier` EIP-712 boundary.

**Repair.** The obsolete interface is removed. `StakingAttestorRegistry`, `ThresholdStakingAttestationVerifier`, and the conventional gateway all use the canonical staking-attestation interfaces.

## Defect 3: canonical unlocked SNRG fork fixture used the wrong decimals

**Evidence.** The supplied fork test asserted that Base unlocked SNRG at `0xb695EB367f61D0Af0baAd5d8D96c8aC2A594058F` has 9 decimals. A direct `decimals()` call to the configured Base mainnet RPC on 2026-08-12 returned `18` for that canonical contract. The separate Base locked/Early Supporter SNRG contract at `0x7E6B6D10d6dCDEf7FDF8EAA10717eFB3eb6E3101` returned `9`.

**Repair.** The unlocked-token fork assertion now checks 18 decimals. This corrects only the real-source test fixture. `SynergyBaseStaking` continues to read and normalize ERC-20 decimals dynamically; no contract behavior or economic term changed.

## Validation required after these repairs

1. Build with the exact pinned toolchain.
2. Run production hardening tests.
3. Install Node dependencies from the committed lockfile with `npm ci`, then run service checks, tests, and the dependency audit.
4. Run all mandatory real Base/Ethereum fork gates using production-approved fixtures.
5. Recompute `MANIFEST.sha256` before any review or deployment decision.

Production execution is authorized only through the fail-closed deployment scripts and the configured production credentials; this defect record itself contains no secret or transaction authority.
