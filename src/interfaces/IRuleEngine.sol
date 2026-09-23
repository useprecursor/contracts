// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRuleEngine {
    event ModuleAdded(address indexed module);
    event ModuleRemoved(address indexed module);
    event ModuleConfigured(address indexed module, bytes32 configHash);

    function token() external view returns (address);
    function modules() external view returns (address[] memory);
    function hasModule(bytes32 moduleId) external view returns (bool);

    /// @notice Runs every enabled module in order and returns the first failing reason code, or `OK`.
    function check(address from, address to, uint256 amount) external view returns (bytes32 reasonCode);

    /// @notice Called by the token after balances change, so stateful modules can update.
    /// @param operator The account that called the token. Used to label lots by acquisition source.
    function transferred(address from, address to, uint256 amount, address operator) external;

    /// @notice Total balance held back by modules (holding periods, vesting). Conservative: a sum, not a max.
    function lockedBalance(address holder) external view returns (uint256);

    function addModule(address module, bytes calldata config) external;
    function removeModule(address module) external;
    function configureModule(address module, bytes calldata config) external;
}
