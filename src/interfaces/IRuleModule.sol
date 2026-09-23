// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A transfer rule. Each module instance serves exactly one RuleEngine (one share class).
interface IRuleModule {
    /// @notice A stable identifier for the module type, such as "REGION" or "ROFR".
    function moduleId() external pure returns (bytes32);
    function engine() external view returns (address);

    /// @notice Returns `OK` or the module's reason code.
    function check(address from, address to, uint256 amount) external view returns (bytes32 reasonCode);

    /// @notice State hook, called by the engine after balances change.
    function onTransfer(address from, address to, uint256 amount, address operator) external;

    /// @notice Replaces or extends the module's configuration. Only the engine may call it.
    function configure(bytes calldata config) external;

    /// @notice Balance this module currently prevents `holder` from transferring.
    function lockedBalance(address holder) external view returns (uint256);
}
