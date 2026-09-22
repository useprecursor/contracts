// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Roles
/// @notice Role identifiers shared by every Precursor contract. `DEFAULT_ADMIN_ROLE` (0x00) is always held by the
///         company's IssuerTimelock, so anything gated on it is both multi-signed and delayed.
library Roles {
    /// @dev The company's operational multi-sig: offerings, windows, distributions, votes, documents.
    bytes32 internal constant ISSUER_ADMIN = keccak256("precursor.role.ISSUER_ADMIN");
    /// @dev The party that keeps the authoritative cap table: mint, burn, freeze, recovery.
    bytes32 internal constant REGISTRAR = keccak256("precursor.role.REGISTRAR");
    /// @dev Precursor's per-company relayer: identity registration and recovery co-signing.
    bytes32 internal constant OPERATOR = keccak256("precursor.role.OPERATOR");
    /// @dev May pause and unpause a share token immediately.
    bytes32 internal constant PAUSER = keccak256("precursor.role.PAUSER");
    /// @dev Contracts allowed to mint without holding REGISTRAR, such as the OfferingVault.
    bytes32 internal constant MINTER = keccak256("precursor.role.MINTER");
    /// @dev Accounts allowed to publish Reference Valuations.
    bytes32 internal constant PUBLISHER = keccak256("precursor.role.PUBLISHER");
    /// @dev Accounts allowed to anchor documents.
    bytes32 internal constant ANCHORER = keccak256("precursor.role.ANCHORER");
}
