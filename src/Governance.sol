// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import {IPrecursorShareToken} from "./interfaces/IPrecursorShareToken.sol";
import {IPrecursorFactory} from "./interfaces/IPrecursorFactory.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {Roles} from "./libraries/Roles.sol";
import {Clock} from "./libraries/Clock.sol";

/// @title Governance
/// @notice Token-weighted shareholder votes with a snapshot block. A proposal covers one or more share classes of the
///         company; a voter's weight is their balance at the snapshot block times each class's display multiplier.
/// @dev Delegation is checkpointed, so it is judged at the snapshot block too. A holder who had delegated at the
///      snapshot is voted by their delegate through `castVoteFor`; a holder who had not delegates nobody and votes
///      themselves. Either way each holder's weight counts once. Delegates must be verified identities.
///      Multipliers are read when the proposal is created. Anyone may finalize after the voting period. The result
///      is the winning option index, or NO_QUORUM.
contract Governance is AccessControl, Initializable {
    using Checkpoints for Checkpoints.Trace208;

    uint8 public constant NO_QUORUM = type(uint8).max;
    uint256 public constant MAX_CLASSES = 8;
    uint256 public constant MAX_OPTIONS = 16;

    struct ProposalParams {
        address[] shareTokens;
        uint48 snapshotBlock;
        uint64 endsAt;
        uint16 quorumBps;
        uint8 options;
        bool binding;
        bytes32 documentHash;
    }

    struct Proposal {
        ProposalParams params;
        uint256[] multipliers;
        uint256[] tallies;
        uint256 totalWeight;
        bool finalized;
        uint8 result;
    }

    event ProposalCreated(uint256 indexed proposalId, uint256 snapshotBlock, uint64 endsAt);
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint8 support, uint256 weight);
    event ProposalFinalized(uint256 indexed proposalId, uint8 result);
    event DelegateChanged(address indexed delegator, address indexed delegatee);

    error InvalidParams();
    error NotCompanyToken();
    error VotingClosed();
    error VotingOpen();
    error AlreadyVoted(address voter);
    error NotDelegate(address delegator);
    error DelegateNotVerified();
    error AlreadyFinalized();
    error NoWeight();

    bytes32 public companyId;
    IPrecursorFactory public factory;
    IIdentityRegistry public identityRegistry;

    Proposal[] private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => Checkpoints.Trace208) private _delegation;

    constructor() {
        _disableInitializers();
    }

    function initialize(bytes32 companyId_, address factory_, address registry, address admin, address issuerAdmin)
        external
        initializer
    {
        companyId = companyId_;
        factory = IPrecursorFactory(factory_);
        identityRegistry = IIdentityRegistry(registry);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.ISSUER_ADMIN, issuerAdmin);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Delegation
    // ---------------------------------------------------------------------------------------------------------------

    function delegate(address delegatee) external {
        if (delegatee != address(0) && !identityRegistry.isVerified(delegatee)) revert DelegateNotVerified();
        _delegation[msg.sender].push(Clock.now48(), uint208(uint160(delegatee)));
        emit DelegateChanged(msg.sender, delegatee);
    }

    function delegateAt(address delegator, uint48 timepoint) public view returns (address) {
        return address(uint160(_delegation[delegator].upperLookupRecent(timepoint)));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Proposals
    // ---------------------------------------------------------------------------------------------------------------

    function propose(ProposalParams calldata p) external onlyRole(Roles.ISSUER_ADMIN) returns (uint256 proposalId) {
        uint256 n = p.shareTokens.length;
        if (n == 0 || n > MAX_CLASSES || p.options < 2 || p.options > MAX_OPTIONS) revert InvalidParams();
        if (p.endsAt <= block.timestamp || p.quorumBps > 10_000) revert InvalidParams();
        if (p.snapshotBlock >= Clock.now48()) revert InvalidParams();

        _proposals.push();
        proposalId = _proposals.length - 1;
        Proposal storage prop = _proposals[proposalId];
        prop.params = p;
        prop.tallies = new uint256[](p.options);
        prop.multipliers = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address token = p.shareTokens[i];
            if (factory.shareClassOf(token).companyId != companyId) revert NotCompanyToken();
            for (uint256 j; j < i; ++j) {
                if (p.shareTokens[j] == token) revert InvalidParams();
            }
            prop.multipliers[i] = IPrecursorShareToken(token).uiMultiplier();
        }
        emit ProposalCreated(proposalId, p.snapshotBlock, p.endsAt);
    }

    function castVote(uint256 proposalId, uint8 option) external {
        Proposal storage prop = _open(proposalId, option);
        address current = delegateAt(msg.sender, prop.params.snapshotBlock);
        if (current != address(0) && current != msg.sender) revert NotDelegate(msg.sender);
        uint256 weight = _record(proposalId, prop, msg.sender);
        if (weight == 0) revert NoWeight();
        prop.tallies[option] += weight;
        prop.totalWeight += weight;
        emit VoteCast(proposalId, msg.sender, option, weight);
    }

    /// @notice A delegate votes the weight of holders who had delegated to them at the snapshot block.
    function castVoteFor(uint256 proposalId, uint8 option, address[] calldata delegators) external {
        Proposal storage prop = _open(proposalId, option);
        uint256 weight;
        for (uint256 i; i < delegators.length; ++i) {
            address d = delegators[i];
            if (delegateAt(d, prop.params.snapshotBlock) != msg.sender) revert NotDelegate(d);
            weight += _record(proposalId, prop, d);
        }
        if (weight == 0) revert NoWeight();
        prop.tallies[option] += weight;
        prop.totalWeight += weight;
        emit VoteCast(proposalId, msg.sender, option, weight);
    }

    function finalize(uint256 proposalId) external {
        Proposal storage prop = _proposals[proposalId];
        if (prop.finalized) revert AlreadyFinalized();
        if (block.timestamp < prop.params.endsAt) revert VotingOpen();
        prop.finalized = true;

        uint256 eligible;
        for (uint256 i; i < prop.params.shareTokens.length; ++i) {
            uint256 supply = IPrecursorShareToken(prop.params.shareTokens[i]).totalSupplyAt(prop.params.snapshotBlock);
            eligible += (supply * prop.multipliers[i]) / 1e18;
        }

        uint8 result = NO_QUORUM;
        if (prop.totalWeight * 10_000 >= eligible * prop.params.quorumBps && prop.totalWeight != 0) {
            uint256 best;
            for (uint8 o; o < prop.params.options; ++o) {
                if (prop.tallies[o] > best) {
                    best = prop.tallies[o];
                    result = o;
                }
            }
        }
        prop.result = result;
        emit ProposalFinalized(proposalId, result);
    }

    function proposal(uint256 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    function weightOf(uint256 proposalId, address voter) public view returns (uint256 weight) {
        Proposal storage prop = _proposals[proposalId];
        for (uint256 i; i < prop.params.shareTokens.length; ++i) {
            uint256 balance =
                IPrecursorShareToken(prop.params.shareTokens[i]).balanceOfAt(voter, prop.params.snapshotBlock);
            weight += (balance * prop.multipliers[i]) / 1e18;
        }
    }

    function _open(uint256 proposalId, uint8 option) private view returns (Proposal storage prop) {
        prop = _proposals[proposalId];
        if (prop.finalized || block.timestamp >= prop.params.endsAt) revert VotingClosed();
        if (option >= prop.params.options) revert InvalidParams();
    }

    function _record(uint256 proposalId, Proposal storage, address voter) private returns (uint256) {
        if (hasVoted[proposalId][voter]) revert AlreadyVoted(voter);
        hasVoted[proposalId][voter] = true;
        return weightOf(proposalId, voter);
    }
}
