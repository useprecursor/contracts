// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IPrecursorShareToken} from "./interfaces/IPrecursorShareToken.sol";
import {ReasonCodes} from "./libraries/ReasonCodes.sol";

/// @title PoolGate
/// @notice The hook a permissioned AMM pool calls before swaps and liquidity changes for one share class. It makes
///         sure the end recipient of shares, and every liquidity provider, passes the share class rules.
/// @dev The pool itself must hold a VENUE claim for this token in the company's IdentityRegistry, which makes it an
///      agent: the token then treats it as pass-through and applies rules to the people on either side. The token
///      already enforces recipient rules when the pool sends shares, so this gate's main job is to fail early with a
///      clear reason code and to restrict LP positions, which are not share tokens themselves.
///      Share classes with a right of first refusal cannot enable pools, because the right cannot be exercised
///      against an instant swap.
contract PoolGate is AccessControl, Initializable {
    event PoolRegistered(address indexed pool);
    event PoolRemoved(address indexed pool);

    error ROFRIncompatible();
    error NotVenue();
    error UnknownPool();

    IPrecursorShareToken public token;
    mapping(address => bool) public isPool;

    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address admin) external initializer {
        token = IPrecursorShareToken(token_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function registerPool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token.ruleEngine().hasModule("ROFR")) revert ROFRIncompatible();
        if (!token.isAgent(pool)) revert NotVenue();
        isPool[pool] = true;
        emit PoolRegistered(pool);
    }

    function removePool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isPool[pool]) revert UnknownPool();
        isPool[pool] = false;
        emit PoolRemoved(pool);
    }

    /// @notice Reason code for delivering `amount` shares from `pool` to `recipient`.
    function checkSwap(address pool, address recipient, uint256 amount) public view returns (bytes32) {
        if (!isPool[pool]) return ReasonCodes.NOT_ELIGIBLE;
        (, bytes32 code) = token.canTransfer(pool, recipient, amount);
        return code;
    }

    /// @notice Reason code for `provider` holding a liquidity position. Providers must pass every recipient-side
    ///         rule, as if they were receiving shares.
    function checkLiquidityProvider(address pool, address provider) public view returns (bytes32) {
        if (!isPool[pool]) return ReasonCodes.NOT_ELIGIBLE;
        (, bytes32 code) = token.canTransfer(pool, provider, 0);
        return code;
    }

    function beforeSwap(address recipient, uint256 sharesOut) external view {
        _require(checkSwap(msg.sender, recipient, sharesOut));
    }

    function beforeAddLiquidity(address provider) external view {
        _require(checkLiquidityProvider(msg.sender, provider));
    }

    function beforeTransferPosition(address, address to) external view {
        _require(checkLiquidityProvider(msg.sender, to));
    }

    function _require(bytes32 code) private pure {
        if (code != ReasonCodes.OK) revert IPrecursorShareToken.TransferNotAllowed(code);
    }
}
