// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IRuleModule} from "../interfaces/IRuleModule.sol";
import {IPrecursorShareToken} from "../interfaces/IPrecursorShareToken.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";

/// @title BaseModule
/// @notice Shared plumbing for transfer rule modules. A module instance is bound to one engine and one token.
/// @dev "System" parties are the zero address (mint or burn) and agents (escrow contracts and approved venues).
///      Recipient-side rules skip system recipients and sender-side rules skip system senders, so rules apply to the
///      real holders at each end of a trade.
abstract contract BaseModule is IRuleModule, Initializable {
    error OnlyEngine();
    error InvalidConfig();

    address public engine;
    IPrecursorShareToken public token;
    IIdentityRegistry public registry;

    constructor() {
        _disableInitializers();
    }

    function initialize(address engine_, address token_) external initializer {
        if (engine_ == address(0) || token_ == address(0)) revert InvalidConfig();
        engine = engine_;
        token = IPrecursorShareToken(token_);
        registry = IPrecursorShareToken(token_).identityRegistry();
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert OnlyEngine();
        _;
    }

    function configure(bytes calldata config) external onlyEngine {
        _configure(config);
    }

    function onTransfer(address from, address to, uint256 amount, address operator) external onlyEngine {
        _onTransfer(from, to, amount, operator);
    }

    function lockedBalance(address) external view virtual returns (uint256) {
        return 0;
    }

    function _configure(bytes calldata config) internal virtual;

    function _onTransfer(address from, address to, uint256 amount, address operator) internal virtual {}

    function _isSystem(address account) internal view returns (bool) {
        return account == address(0) || token.isAgent(account);
    }

    function _identity(address wallet) internal view returns (address) {
        return registry.identityOf(wallet);
    }
}

/// @title IdentityBalanceModule
/// @notice Base for modules that reason about holdings per identity rather than per wallet (holder caps, ownership
///         caps, vesting). Balances are tracked from the moment the module is added, so add these modules when the
///         share class is deployed, before the first mint.
abstract contract IdentityBalanceModule is BaseModule {
    mapping(address => uint256) public identityBalance;

    function _onTransfer(address from, address to, uint256 amount, address) internal virtual override {
        address fromId = _isSystem(from) ? address(0) : _identity(from);
        address toId = _isSystem(to) ? address(0) : _identity(to);
        if (fromId == toId) return;
        if (fromId != address(0)) {
            uint256 before = identityBalance[fromId];
            uint256 next = before > amount ? before - amount : 0;
            identityBalance[fromId] = next;
            if (before != 0 && next == 0) _onIdentityEmptied(fromId);
        }
        if (toId != address(0)) {
            uint256 before = identityBalance[toId];
            identityBalance[toId] = before + amount;
            if (before == 0 && amount != 0) _onIdentityFunded(toId);
        }
    }

    function _onIdentityEmptied(address identity) internal virtual {}

    function _onIdentityFunded(address identity) internal virtual {}
}
