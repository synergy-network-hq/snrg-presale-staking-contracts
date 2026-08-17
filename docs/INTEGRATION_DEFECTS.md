# Documented integration defects

## 2026-08-11 — Ethereum presale-voucher allocation ABI drift

### Evidence

`EthereumAllocationVoucherAdapter` originally declared `allocationOf(uint256)` as a
15-value flattened tuple beginning with `address buyer`.  The deployed Ethereum
presale voucher (`SNRGClaimVoucherSoulboundV2`,
`0xF913ddCe2Bf4FCA896332086c08B90A1A06fc7A9`) returns its `Allocation` struct as
a 21-component ABI tuple: it begins with `uint64 ledgerId, bytes32 saleIdHash,
address walletAddress, address purchaserAddress`, and includes a nested
`VestingTerms` tuple before `bool redeemed`.

The original adapter would have decoded `saleIdHash` as an SNRG amount and therefore
could create incorrect stake entitlements.  This is a source-ABI integration defect,
not a change to staking economics or reward terms.

### Remediation

The adapter interface now mirrors the deployed V2 struct exactly and accepts only the
voucher's canonical non-zero `tokenFingerprint` as its allocation identity.  There is
no generated identity fallback.  The adapter remains read-only and all fixed staking
economics are unchanged.

### Deployment gate

The repaired adapter must be compiled with Solidity `0.8.36` and OpenZeppelin `5.6.1`,
then fork-tested against the live Ethereum voucher before any Ethereum presale-voucher
staking deployment or explorer verification is attempted.
