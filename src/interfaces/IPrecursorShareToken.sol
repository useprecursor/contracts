// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIdentityRegistry} from "./IIdentityRegistry.sol";
import {IRuleEngine} from "./IRuleEngine.sol";

/// @notice The ERC-3643 surface Precursor tokens expose for permissioned-token tooling. Precursor names the
///         compliance contract a "rule engine"; `compliance()` returns the same address.
interface IERC3643 {
    function identityRegistry() external view returns (IIdentityRegistry);
    function compliance() external view returns (address);
    function paused() external view returns (bool);
    function isFrozen(address holder) external view returns (bool);
    function getFrozenTokens(address holder) external view returns (uint256);
}

/// @notice ERC-8056 Scaled UI Amount Extension. Raw balances never change during a corporate action. Display
///         amounts are `raw * uiMultiplier() / 1e18`.
interface IERC8056 {
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);

    function uiMultiplier() external view returns (uint256);
}

interface IPrecursorShareToken is IERC20, IERC3643, IERC8056 {
    event SharesIssued(address indexed to, uint256 amount, bytes32 indexed ref);
    event SharesRedeemed(address indexed from, uint256 amount, bytes32 indexed ref);
    event RecoveryApproved(address indexed lost, address indexed replacement, address indexed approver);
    event RecoveryScheduled(address indexed lost, address indexed replacement, uint64 eta, bytes32 ref);
    event RecoveryExecuted(address indexed lost, address indexed replacement, uint256 amount);
    event RecoveryCancelled(address indexed lost);
    event TokensFrozen(address indexed holder, uint256 amount, bytes32 reason);
    event TokensUnfrozen(address indexed holder, uint256 amount);
    event Paused(bytes32 reason);
    event Unpaused();
    event MultiplierScheduled(uint256 newMultiplier, uint64 effectiveAt);
    event AgentSet(address indexed agent, bool enabled);
    event DocumentsRootUpdated(bytes32 documentsRoot);

    error TransferNotAllowed(bytes32 reasonCode);

    // Identity and transfer rules
    function ruleEngine() external view returns (IRuleEngine);
    function canTransfer(address from, address to, uint256 amount) external view returns (bool ok, bytes32 reasonCode);
    function isAgent(address account) external view returns (bool);

    // Issuer controls
    function mint(address to, uint256 amount, bytes32 ref) external;
    function burn(address from, uint256 amount, bytes32 ref) external;
    function approveRecovery(address lost, address replacement, bytes32 ref) external;
    function cancelRecovery(address lost) external;
    function recover(address lost, address replacement, bytes32 ref) external;
    function freezePartial(address holder, uint256 amount, bytes32 reason) external;
    function unfreezePartial(address holder, uint256 amount) external;
    function pause(bytes32 reason) external;
    function unpause() external;
    function scheduleMultiplier(uint256 newMultiplier, uint64 effectiveAt) external;
    function applyMultiplier() external;

    // Metadata
    function shareClass() external view returns (bytes32);
    function companyId() external view returns (bytes32);
    function documentsRoot() external view returns (bytes32);
    function unlockedBalanceOf(address holder) external view returns (uint256);

    // Snapshots
    function clock() external view returns (uint48);
    function balanceOfAt(address account, uint48 timepoint) external view returns (uint256);
    function totalSupplyAt(uint48 timepoint) external view returns (uint256);
}
