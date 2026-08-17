// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEntitlementAdapter} from "../../contracts/interfaces/IEntitlementAdapter.sol";

contract MockStakeToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 tokenDecimals_) ERC20(name_, symbol_) {
        _tokenDecimals = tokenDecimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract MockBaseVoucherAdapter is IEntitlementAdapter {
    struct Entry {
        address owner;
        uint256 entitlementNwei;
        bytes32 allocationId;
        bool consumed;
    }

    address public immutable override voucher;
    mapping(uint256 tokenId => Entry entry) private _entries;

    constructor(address voucher_) {
        voucher = voucher_;
    }

    function setEntry(uint256 tokenId, Entry calldata entry) external {
        _entries[tokenId] = entry;
    }

    function entitlement(uint256 tokenId)
        external
        view
        override
        returns (address owner, uint256 entitlementNwei, bytes32 allocationId, bool consumed)
    {
        Entry memory entry = _entries[tokenId];
        return (entry.owner, entry.entitlementNwei, entry.allocationId, entry.consumed);
    }
}
