// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {
    EthereumAllocationVoucherAdapter,
    IEthereumAllocationVoucher
} from "../contracts/adapters/EthereumAllocationVoucherAdapter.sol";

/// @dev Test-only source that returns the exact deployed V2 Allocation tuple shape.
contract ExactV2VoucherFixture is IEthereumAllocationVoucher {
    Allocation private _allocation;
    address private _owner;
    bytes32 private _fingerprint;
    bool private _ownerReadForbidden;

    function configure(address owner_, uint96 amountNwei_, bytes32 fingerprint_, bool redeemed_) external {
        _owner = owner_;
        _fingerprint = fingerprint_;
        _allocation = Allocation({
            ledgerId: 88,
            saleIdHash: keccak256("sale"),
            walletAddress: owner_,
            purchaserAddress: owner_,
            networkIdHash: keccak256("ethereum"),
            paymentChainId: 1,
            assetSymbolHash: keccak256("USDC"),
            snrgAmountNwei: amountNwei_,
            paymentAmountRaw: 123_456,
            paymentTokenAddress: address(0x1234),
            paymentTokenDecimals: 6,
            paymentTxHash: keccak256("payment"),
            stageFrom: 1,
            stageTo: 1,
            stageId: 1,
            priceUsdE8: 380_000,
            usdValueE8: 1_000_000,
            purchaseTimestamp: 1_700_000_000,
            sourceHash: keccak256("source"),
            vesting: VestingTerms({vestingStart: 1_700_000_000, cliffSeconds: 0, durationSeconds: 0, initialUnlockBps: 10_000}),
            redeemed: redeemed_
        });
    }

    function forbidOwnerRead() external {
        _ownerReadForbidden = true;
    }

    function ownerOf(uint256) external view returns (address) {
        require(!_ownerReadForbidden, "owner read must be skipped for redeemed voucher");
        return _owner;
    }

    function allocationOf(uint256) external view returns (Allocation memory) {
        return _allocation;
    }

    function tokenFingerprint(uint256) external view returns (bytes32) {
        return _fingerprint;
    }
}

contract EthereumAllocationVoucherAdapterTest is Test {
    address internal constant OWNER = address(0xBEEF);
    bytes32 internal constant FINGERPRINT = keccak256("canonical-allocation");

    ExactV2VoucherFixture private source;
    EthereumAllocationVoucherAdapter private adapter;

    function setUp() external {
        source = new ExactV2VoucherFixture();
        adapter = new EthereumAllocationVoucherAdapter(address(source));
    }

    function testReadsExactV2AllocationTuple() external {
        source.configure(OWNER, 42_000_000_000, FINGERPRINT, false);

        (address owner, uint256 amountNwei, bytes32 allocationId, bool consumed) = adapter.entitlement(1);
        assertEq(owner, OWNER);
        assertEq(amountNwei, 42_000_000_000);
        assertEq(allocationId, FINGERPRINT);
        assertFalse(consumed);
    }

    function testRedeemedSourceSkipsOwnerRead() external {
        source.configure(OWNER, 42_000_000_000, FINGERPRINT, true);
        source.forbidOwnerRead();

        (address owner, uint256 amountNwei, bytes32 allocationId, bool consumed) = adapter.entitlement(1);
        assertEq(owner, address(0));
        assertEq(amountNwei, 42_000_000_000);
        assertEq(allocationId, FINGERPRINT);
        assertTrue(consumed);
    }

    function testRejectsSourceWithoutCanonicalFingerprint() external {
        source.configure(OWNER, 42_000_000_000, bytes32(0), false);
        vm.expectRevert(abi.encodeWithSelector(EthereumAllocationVoucherAdapter.MissingTokenFingerprint.selector, 1));
        adapter.entitlement(1);
    }
}
