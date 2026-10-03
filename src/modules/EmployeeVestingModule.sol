// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IdentityBalanceModule} from "./BaseModule.sol";
import {ReasonCodes} from "../libraries/ReasonCodes.sol";
import {Roles} from "../libraries/Roles.sol";

/// @title EmployeeVestingModule
/// @notice Locks unvested employee shares and releases them on schedule. Schedules belong to identities, so an
///         employee with several wallets is treated as one holder.
/// @dev Config (through the engine, so through the IssuerTimelock): `abi.encode(uint8 action, bytes payload)`.
///      - action 0: `payload = abi.encode(bool accelerationEnabled)`
///      - action 1: `payload = abi.encode(address identity, uint256 index)` accelerates one grant to fully vested.
///      Grants themselves come from the cap table, so the token's REGISTRAR adds them directly with `addGrants`.
///      Vesting is linear after the cliff. Vested shares stay subject to every other rule.
contract EmployeeVestingModule is IdentityBalanceModule {
    uint256 public constant MAX_GRANTS = 16;
    uint8 public constant ACTION_SET = 0;
    uint8 public constant ACTION_ACCELERATE = 1;

    struct Grant {
        uint64 start;
        uint64 cliff;
        uint64 duration;
        uint256 total;
        bool accelerated;
    }

    event GrantAdded(
        address indexed identity, uint256 index, uint64 start, uint64 cliff, uint64 duration, uint256 total
    );
    event GrantAccelerated(address indexed identity, uint256 index);

    error NotRegistrar();
    error AccelerationDisabled();
    error TooManyGrants();

    bool public accelerationEnabled;
    mapping(address => Grant[]) private _grants;

    function moduleId() external pure returns (bytes32) {
        return "EMPLOYEE_VESTING";
    }

    function grantsOf(address identity) external view returns (Grant[] memory) {
        return _grants[identity];
    }

    function addGrants(address identity, Grant[] calldata grants) external {
        if (!IAccessControl(address(token)).hasRole(Roles.REGISTRAR, msg.sender)) revert NotRegistrar();
        Grant[] storage list = _grants[identity];
        if (list.length + grants.length > MAX_GRANTS) revert TooManyGrants();
        for (uint256 i; i < grants.length; ++i) {
            Grant calldata g = grants[i];
            if (g.duration == 0 || g.cliff > g.duration) revert InvalidConfig();
            list.push(Grant({start: g.start, cliff: g.cliff, duration: g.duration, total: g.total, accelerated: false}));
            emit GrantAdded(identity, list.length - 1, g.start, g.cliff, g.duration, g.total);
        }
    }

    function unvestedOf(address identity) public view returns (uint256 unvested) {
        Grant[] storage list = _grants[identity];
        for (uint256 i; i < list.length; ++i) {
            Grant storage g = list[i];
            unvested += g.total - _vested(g);
        }
    }

    function check(address from, address, uint256 amount) external view returns (bytes32) {
        if (_isSystem(from)) return ReasonCodes.OK;
        address id = _identity(from);
        if (id == address(0)) return ReasonCodes.OK;
        uint256 unvested = unvestedOf(id);
        if (unvested == 0) return ReasonCodes.OK;
        return amount + unvested > identityBalance[id] ? ReasonCodes.UNVESTED : ReasonCodes.OK;
    }

    function lockedBalance(address holder) external view override returns (uint256) {
        uint256 unvested = unvestedOf(_identity(holder));
        uint256 balance = token.balanceOf(holder);
        return unvested > balance ? balance : unvested;
    }

    function _vested(Grant storage g) private view returns (uint256) {
        if (g.accelerated || block.timestamp >= uint256(g.start) + g.duration) return g.total;
        if (block.timestamp < uint256(g.start) + g.cliff) return 0;
        return (g.total * (block.timestamp - g.start)) / g.duration;
    }

    function _configure(bytes calldata config) internal override {
        (uint8 action, bytes memory payload) = abi.decode(config, (uint8, bytes));
        if (action == ACTION_SET) {
            accelerationEnabled = abi.decode(payload, (bool));
        } else if (action == ACTION_ACCELERATE) {
            if (!accelerationEnabled) revert AccelerationDisabled();
            (address identity, uint256 index) = abi.decode(payload, (address, uint256));
            _grants[identity][index].accelerated = true;
            emit GrantAccelerated(identity, index);
        } else {
            revert InvalidConfig();
        }
    }
}
