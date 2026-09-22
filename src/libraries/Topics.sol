// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Topics
/// @notice Claim topics recognised by the IdentityRegistry, as left-aligned bytes32 strings.
library Topics {
    /// @dev Identity verification completed. Data is empty.
    bytes32 internal constant IDENTITY_VERIFIED = "IDENTITY_VERIFIED";
    /// @dev Investor eligibility. Data is `abi.encode(uint8 tier)`.
    bytes32 internal constant INVESTOR_ELIGIBLE = "INVESTOR_ELIGIBLE";
    /// @dev Country of residence. Data is `abi.encode(bytes2 iso3166Alpha2)`.
    bytes32 internal constant REGION = "REGION";
    /// @dev Employment. Data is `abi.encode(bytes32 companyId)`.
    bytes32 internal constant EMPLOYEE_OF = "EMPLOYEE_OF";
    /// @dev Screening passed. Data is `abi.encode(uint64 lastScreenedAt)`.
    bytes32 internal constant SCREENED = "SCREENED";
    /// @dev An approved venue contract, such as a permissioned pool. Data is `abi.encode(address shareToken)`.
    bytes32 internal constant VENUE = "VENUE";
}
