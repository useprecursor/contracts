// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IValuationOracle} from "./interfaces/IValuationOracle.sol";
import {IPrecursorShareToken} from "./interfaces/IPrecursorShareToken.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title ValuationOracle
/// @notice Publishes the Reference Valuation for one share class: a dated, sourced price per share in USD with 8
///         decimals. It speaks Chainlink's AggregatorV3 interface so lending markets and dashboards can read it
///         unchanged, and adds `latestValuation()` for the source, date and supporting document.
/// @dev A Reference Valuation is not a live market price. `updatedAt` equals `asOf`, the date the valuation refers
///      to, so consumers applying staleness checks see the true age of the number. Publishing is blocked while the
///      share token is paused, so the oracle holds its last value across a pause or a corporate action.
contract ValuationOracle is IValuationOracle, AccessControl, Initializable {
    struct Round {
        int256 price;
        uint8 source;
        uint64 asOf;
        uint64 publishedAt;
        bytes32 documentHash;
    }

    error InvalidPrice();
    error InvalidSource();
    error InvalidDate();
    error TokenPaused();
    error NoData();

    address private _token;
    Round[] private _rounds;

    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address admin, address[] calldata publishers) external initializer {
        _token = token_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i; i < publishers.length; ++i) {
            _grantRole(Roles.PUBLISHER, publishers[i]);
        }
    }

    function token() external view returns (address) {
        return _token;
    }

    function publish(int256 price, uint8 source, uint64 asOf, bytes32 documentHash) external onlyRole(Roles.PUBLISHER) {
        if (price <= 0) revert InvalidPrice();
        if (source > uint8(Source.WINDOW_CLEARING)) revert InvalidSource();
        if (asOf == 0 || asOf > block.timestamp) revert InvalidDate();
        if (IPrecursorShareToken(_token).paused()) revert TokenPaused();
        _rounds.push(
            Round({
                price: price,
                source: source,
                asOf: asOf,
                publishedAt: uint64(block.timestamp),
                documentHash: documentHash
            })
        );
        emit ValuationPublished(price, source, asOf, documentHash);
    }

    function latestValuation() external view returns (int256 price, uint8 source, uint64 asOf, bytes32 documentHash) {
        if (_rounds.length == 0) revert NoData();
        Round storage r = _rounds[_rounds.length - 1];
        return (r.price, r.source, r.asOf, r.documentHash);
    }

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    // AggregatorV3Interface

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external view returns (string memory) {
        return string.concat(IERC20Metadata(_token).symbol(), " / USD reference valuation");
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        if (roundId == 0 || roundId > _rounds.length) revert NoData();
        Round storage r = _rounds[roundId - 1];
        return (roundId, r.price, r.asOf, r.asOf, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (_rounds.length == 0) revert NoData();
        return getRoundData(uint80(_rounds.length));
    }
}
