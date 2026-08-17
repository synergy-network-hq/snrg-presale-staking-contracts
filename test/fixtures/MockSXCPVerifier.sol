// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ISXCPVerifier} from "../../contracts/interfaces/ISXCPVerifier.sol";

/// @dev Test-only verifier used to isolate the v5 gateway and reward-ledger state machine.
///      It is never a production SXCP/Aegis implementation.
contract MockSXCPVerifier is ISXCPVerifier {
    bool public result = true;

    function setResult(bool result_) external {
        result = result_;
    }

    function verifyFact(FactAttestation calldata, bytes calldata) external view returns (bool) {
        return result;
    }
}
