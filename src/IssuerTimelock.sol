// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title IssuerTimelock
/// @notice A company's timelocked multi-sig. It holds DEFAULT_ADMIN_ROLE on every contract in the company's set, so
///         sensitive changes (rule changes, upgrades, verifier changes, role grants) need M-of-N signer approval and
///         then wait out a delay that depends on the function being called. The pending action is public for the
///         whole delay.
/// @dev Delays are keyed by function selector. Each selector has a floor the company cannot go below; delays can be
///      lengthened through the timelock itself. Approvals are recounted against the current signer set at execution,
///      so removing a signer also removes their pending approvals.
contract IssuerTimelock is Initializable, ReentrancyGuard {
    uint256 public constant MAX_SIGNERS = 20;
    uint64 public constant DEFAULT_DELAY = 48 hours;
    uint64 public constant MODULE_DELAY = 24 hours;
    uint64 public constant UPGRADE_DELAY = 7 days;

    // Selectors with their own floors.
    bytes4 internal constant ADD_MODULE = bytes4(keccak256("addModule(address,bytes)"));
    bytes4 internal constant REMOVE_MODULE = bytes4(keccak256("removeModule(address)"));
    bytes4 internal constant CONFIGURE_MODULE = bytes4(keccak256("configureModule(address,bytes)"));
    bytes4 internal constant UPGRADE_TO_AND_CALL = bytes4(keccak256("upgradeToAndCall(address,bytes)"));

    struct Action {
        address target;
        uint256 value;
        bytes data;
        uint64 eta;
        bool executed;
        bool cancelled;
        address[] approvers;
    }

    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ThresholdChanged(uint256 threshold);
    event DelayChanged(bytes4 indexed selector, uint64 delay);
    event ActionProposed(bytes32 indexed id, address indexed proposer, address target, uint256 value, bytes data);
    event ActionApproved(bytes32 indexed id, address indexed signer);
    event ActionQueued(bytes32 indexed id, uint64 eta);
    event ActionExecuted(bytes32 indexed id);
    event ActionCancelled(bytes32 indexed id);

    error NotSigner();
    error OnlySelf();
    error InvalidSigners();
    error InvalidThreshold();
    error UnknownAction();
    error ActionExists();
    error AlreadyApproved();
    error NotQueued();
    error TooEarly();
    error ActionClosed();
    error DelayBelowMinimum();
    error CallFailed(bytes returndata);

    address[] private _signers;
    mapping(address => bool) public isSigner;
    uint256 public threshold;
    mapping(bytes4 => uint64) private _delayOverride;
    mapping(bytes32 => Action) private _actions;

    constructor() {
        _disableInitializers();
    }

    function initialize(address[] calldata signers_, uint256 threshold_) external initializer {
        if (signers_.length == 0 || signers_.length > MAX_SIGNERS) revert InvalidSigners();
        for (uint256 i; i < signers_.length; ++i) {
            _addSigner(signers_[i]);
        }
        _setThreshold(threshold_);
    }

    modifier onlySigner() {
        if (!isSigner[msg.sender]) revert NotSigner();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------------

    function hashAction(address target, uint256 value, bytes calldata data, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data, salt));
    }

    function propose(address target, uint256 value, bytes calldata data, bytes32 salt)
        external
        onlySigner
        returns (bytes32 id)
    {
        id = hashAction(target, value, data, salt);
        Action storage a = _actions[id];
        if (a.target != address(0)) revert ActionExists();
        a.target = target;
        a.value = value;
        a.data = data;
        emit ActionProposed(id, msg.sender, target, value, data);
        _approve(id, a);
    }

    function approve(bytes32 id) external onlySigner {
        Action storage a = _actions[id];
        if (a.target == address(0)) revert UnknownAction();
        _approve(id, a);
    }

    function execute(bytes32 id) external payable nonReentrant returns (bytes memory) {
        Action storage a = _actions[id];
        if (a.target == address(0)) revert UnknownAction();
        if (a.executed || a.cancelled) revert ActionClosed();
        if (a.eta == 0 || _validApprovals(a) < threshold) revert NotQueued();
        if (block.timestamp < a.eta) revert TooEarly();
        a.executed = true;
        (bool ok, bytes memory ret) = a.target.call{value: a.value}(a.data);
        if (!ok) revert CallFailed(ret);
        emit ActionExecuted(id);
        return ret;
    }

    function cancel(bytes32 id) external onlySigner {
        Action storage a = _actions[id];
        if (a.target == address(0)) revert UnknownAction();
        if (a.executed || a.cancelled) revert ActionClosed();
        a.cancelled = true;
        emit ActionCancelled(id);
    }

    function action(bytes32 id) external view returns (Action memory) {
        return _actions[id];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Delays
    // ---------------------------------------------------------------------------------------------------------------

    function minDelay(bytes4 selector) public pure returns (uint64) {
        if (selector == UPGRADE_TO_AND_CALL) return UPGRADE_DELAY;
        if (selector == ADD_MODULE || selector == REMOVE_MODULE || selector == CONFIGURE_MODULE) return MODULE_DELAY;
        return DEFAULT_DELAY;
    }

    function delayFor(bytes4 selector) public view returns (uint64) {
        uint64 custom = _delayOverride[selector];
        uint64 floor = minDelay(selector);
        return custom > floor ? custom : floor;
    }

    function setDelay(bytes4 selector, uint64 delay) external onlySelf {
        if (delay < minDelay(selector)) revert DelayBelowMinimum();
        _delayOverride[selector] = delay;
        emit DelayChanged(selector, delay);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Signers (only through the timelock itself)
    // ---------------------------------------------------------------------------------------------------------------

    function signers() external view returns (address[] memory) {
        return _signers;
    }

    function addSigner(address signer) external onlySelf {
        _addSigner(signer);
    }

    function removeSigner(address signer) external onlySelf {
        if (!isSigner[signer]) revert InvalidSigners();
        isSigner[signer] = false;
        uint256 n = _signers.length;
        for (uint256 i; i < n; ++i) {
            if (_signers[i] == signer) {
                _signers[i] = _signers[n - 1];
                _signers.pop();
                break;
            }
        }
        if (threshold > _signers.length) revert InvalidThreshold();
        emit SignerRemoved(signer);
    }

    function setThreshold(uint256 threshold_) external onlySelf {
        _setThreshold(threshold_);
    }

    receive() external payable {}

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    function _approve(bytes32 id, Action storage a) private {
        if (a.executed || a.cancelled) revert ActionClosed();
        for (uint256 i; i < a.approvers.length; ++i) {
            if (a.approvers[i] == msg.sender) revert AlreadyApproved();
        }
        a.approvers.push(msg.sender);
        emit ActionApproved(id, msg.sender);
        if (a.eta == 0 && _validApprovals(a) >= threshold) {
            a.eta = uint64(block.timestamp) + delayFor(_selector(a.data));
            emit ActionQueued(id, a.eta);
        }
    }

    function _validApprovals(Action storage a) private view returns (uint256 n) {
        for (uint256 i; i < a.approvers.length; ++i) {
            if (isSigner[a.approvers[i]]) ++n;
        }
    }

    function _selector(bytes memory data) private pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(data, 32))
        }
    }

    function _addSigner(address signer) private {
        if (signer == address(0) || isSigner[signer] || _signers.length >= MAX_SIGNERS) revert InvalidSigners();
        isSigner[signer] = true;
        _signers.push(signer);
        emit SignerAdded(signer);
    }

    function _setThreshold(uint256 threshold_) private {
        if (threshold_ == 0 || threshold_ > _signers.length) revert InvalidThreshold();
        threshold = threshold_;
        emit ThresholdChanged(threshold_);
    }
}
