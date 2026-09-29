// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseModule} from "./BaseModule.sol";
import {ReasonCodes} from "../libraries/ReasonCodes.sol";
import {Topics} from "../libraries/Topics.sol";

/// @title EligibilityModule
/// @notice Requires recipients to hold a valid INVESTOR_ELIGIBLE claim at or above a minimum tier.
/// @dev Config: `abi.encode(uint8 minimumTier, bool exemptEmployees)`. When `exemptEmployees` is set, an identity
///      with a valid EMPLOYEE_OF claim for this company skips the tier check.
contract EligibilityModule is BaseModule {
    uint8 public minimumTier;
    bool public exemptEmployees;

    function moduleId() external pure returns (bytes32) {
        return "ELIGIBILITY";
    }

    function check(address, address to, uint256) external view returns (bytes32) {
        if (_isSystem(to)) return ReasonCodes.OK;
        if (exemptEmployees && registry.hasValidClaim(to, Topics.EMPLOYEE_OF)) {
            bytes32 employer = abi.decode(registry.claimData(to, Topics.EMPLOYEE_OF), (bytes32));
            if (employer == token.companyId()) return ReasonCodes.OK;
        }
        if (!registry.hasValidClaim(to, Topics.INVESTOR_ELIGIBLE)) return ReasonCodes.NOT_ELIGIBLE;
        uint8 tier = abi.decode(registry.claimData(to, Topics.INVESTOR_ELIGIBLE), (uint8));
        return tier >= minimumTier ? ReasonCodes.OK : ReasonCodes.NOT_ELIGIBLE;
    }

    function _configure(bytes calldata config) internal override {
        (minimumTier, exemptEmployees) = abi.decode(config, (uint8, bool));
    }
}
