// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseModule} from "./BaseModule.sol";
import {ReasonCodes} from "../libraries/ReasonCodes.sol";

/// @title ROFRModule
/// @notice Gives the company, or a designee, a right of first refusal on direct transfers.
/// @dev Config: `abi.encode(address holder, uint32 noticePeriod, address[] exemptVenues)`.
///      A holder who wants to transfer calls `propose(to, amount)`. The transfer returns ROFR_PENDING until the notice
///      period has passed or the right holder waives. If the right holder exercises instead, only a transfer to the
///      right holder is allowed for that proposal; payment is settled between the parties (for example through RFQ).
///      Transfers through exempt venues, such as the LiquidityWindow, where the right is exercised in-line as a
///      priority bid, are not subject to the notice flow.
contract ROFRModule is BaseModule {
    uint256 public constant MAX_VENUES = 16;

    enum Status {
        NONE,
        PENDING,
        WAIVED,
        EXERCISED
    }

    struct Proposal {
        uint256 amount;
        uint64 proposedAt;
        Status status;
    }

    event TransferProposed(address indexed from, address indexed to, uint256 amount, uint64 noticeEndsAt);
    event RightWaived(address indexed from, address indexed to);
    event RightExercised(address indexed from, address indexed to, uint256 amount);

    error NotRightHolder();
    error NoProposal();

    address public holder;
    uint32 public noticePeriod;
    address[] private _exemptVenues;
    mapping(address => bool) public isExemptVenue;
    mapping(address => mapping(address => Proposal)) public proposals;

    function moduleId() external pure returns (bytes32) {
        return "ROFR";
    }

    function exemptVenues() external view returns (address[] memory) {
        return _exemptVenues;
    }

    function propose(address to, uint256 amount) external {
        proposals[msg.sender][to] =
            Proposal({amount: amount, proposedAt: uint64(block.timestamp), status: Status.PENDING});
        emit TransferProposed(msg.sender, to, amount, uint64(block.timestamp) + noticePeriod);
    }

    function waive(address from, address to) external {
        Proposal storage p = _pending(from, to);
        p.status = Status.WAIVED;
        emit RightWaived(from, to);
    }

    function exercise(address from, address to) external {
        Proposal storage p = _pending(from, to);
        p.status = Status.EXERCISED;
        emit RightExercised(from, to, p.amount);
    }

    function check(address from, address to, uint256 amount) external view returns (bytes32) {
        if (_isSystem(from) || from == holder || to == holder) return ReasonCodes.OK;
        if (isExemptVenue[from] || isExemptVenue[to]) return ReasonCodes.OK;
        Proposal storage p = proposals[from][to];
        if (amount > p.amount) return ReasonCodes.ROFR_PENDING;
        if (p.status == Status.WAIVED) return ReasonCodes.OK;
        if (p.status == Status.PENDING && block.timestamp >= uint256(p.proposedAt) + noticePeriod) {
            return ReasonCodes.OK;
        }
        return ReasonCodes.ROFR_PENDING;
    }

    function _onTransfer(address from, address to, uint256 amount, address) internal override {
        Proposal storage p = proposals[from][to];
        if (p.status == Status.NONE) return;
        if (p.amount <= amount) delete proposals[from][to];
        else p.amount -= amount;
    }

    function _pending(address from, address to) private view returns (Proposal storage p) {
        if (msg.sender != holder) revert NotRightHolder();
        p = proposals[from][to];
        if (p.status != Status.PENDING) revert NoProposal();
    }

    function _configure(bytes calldata config) internal override {
        (address holder_, uint32 notice, address[] memory venues) = abi.decode(config, (address, uint32, address[]));
        if (holder_ == address(0) || venues.length > MAX_VENUES) revert InvalidConfig();
        holder = holder_;
        noticePeriod = notice;
        for (uint256 i; i < _exemptVenues.length; ++i) {
            isExemptVenue[_exemptVenues[i]] = false;
        }
        delete _exemptVenues;
        for (uint256 i; i < venues.length; ++i) {
            isExemptVenue[venues[i]] = true;
            _exemptVenues.push(venues[i]);
        }
    }
}
