// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPrecursorShareToken} from "./interfaces/IPrecursorShareToken.sol";
import {IPrecursorFactory} from "./interfaces/IPrecursorFactory.sol";
import {IValuationOracle} from "./interfaces/IValuationOracle.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title OfferingVault
/// @notice Runs a company's primary offerings. Investors subscribe in a stablecoin that stays escrowed in this
///         contract. At close, if the minimum was met, the vault mints shares to every accepted subscriber and
///         releases the funds to the company's treasury in the same transaction. If the minimum was not met, every
///         subscriber can withdraw their full subscription. Refunds never expire.
/// @dev Oversubscription above `maxRaise` is allocated pro-rata, with no time priority. Each subscriber is checked
///      against the share class rules again at close; a subscriber who no longer passes is refunded instead of minted.
contract OfferingVault is AccessControl, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_SUBSCRIBERS = 500;
    uint256 public constant MAX_REQUIRED_CLAIMS = 8;
    uint16 public constant MAX_FEE_BPS = 500;

    enum State {
        SCHEDULED,
        OPEN,
        CLOSED,
        FAILED
    }

    struct OfferingParams {
        address shareToken;
        uint256 pricePerShare; // stablecoin units per whole share (1e18 raw token units)
        uint256 minRaise;
        uint256 maxRaise;
        uint256 minTicket;
        uint64 opensAt;
        uint64 closesAt;
        address stablecoin;
        bytes32[] requiredClaims;
        address treasury;
        uint256 documentId;
    }

    struct Offering {
        OfferingParams params;
        uint256 raised;
        uint256 accepted;
        uint256 sharesIssued;
        bool closed;
        bool failed;
    }

    event OfferingCreated(uint256 indexed offeringId);
    event Subscribed(uint256 indexed offeringId, address indexed investor, uint256 amount);
    event OfferingClosed(uint256 indexed offeringId, uint256 raised, uint256 sharesIssued);
    event OfferingFailed(uint256 indexed offeringId);
    event Refunded(uint256 indexed offeringId, address indexed investor, uint256 amount);
    event FeeUpdated(address recipient, uint16 feeBps);

    error InvalidParams();
    error NotCompanyToken();
    error NotOpen();
    error BelowMinimumTicket();
    error MissingClaim(bytes32 topic);
    error TooManySubscribers();
    error CannotClose();
    error AlreadyFinal();
    error NothingToRefund();

    bytes32 public companyId;
    IPrecursorFactory public factory;
    address public feeRecipient;
    uint16 public feeBps;

    Offering[] private _offerings;
    mapping(uint256 => address[]) private _subscribers;
    mapping(uint256 => mapping(address => uint256)) public subscriptionOf;
    mapping(uint256 => mapping(address => uint256)) public refundableOf;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        bytes32 companyId_,
        address factory_,
        address admin,
        address issuerAdmin,
        address feeRecipient_,
        uint16 feeBps_
    ) external initializer {
        companyId = companyId_;
        factory = IPrecursorFactory(factory_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.ISSUER_ADMIN, issuerAdmin);
        _setFee(feeRecipient_, feeBps_);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Issuer
    // ---------------------------------------------------------------------------------------------------------------

    function createOffering(OfferingParams calldata p)
        external
        onlyRole(Roles.ISSUER_ADMIN)
        returns (uint256 offeringId)
    {
        if (factory.shareClassOf(p.shareToken).companyId != companyId) {
            revert NotCompanyToken();
        }
        if (
            p.pricePerShare == 0 || p.maxRaise == 0 || p.minRaise > p.maxRaise || p.minTicket > p.maxRaise
                || p.closesAt <= p.opensAt || p.closesAt <= block.timestamp || p.stablecoin == address(0)
                || p.treasury == address(0) || p.requiredClaims.length > MAX_REQUIRED_CLAIMS
        ) revert InvalidParams();

        _offerings.push();
        offeringId = _offerings.length - 1;
        _offerings[offeringId].params = p;
        emit OfferingCreated(offeringId);
    }

    /// @notice Cancels an offering before it closes. Every subscriber can then withdraw in full.
    function cancelOffering(uint256 offeringId) external onlyRole(Roles.ISSUER_ADMIN) {
        Offering storage o = _offerings[offeringId];
        if (o.closed || o.failed) revert AlreadyFinal();
        o.failed = true;
        emit OfferingFailed(offeringId);
    }

    function setFee(address recipient, uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFee(recipient, bps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Investors
    // ---------------------------------------------------------------------------------------------------------------

    function subscribe(uint256 offeringId, uint256 amount) external nonReentrant {
        Offering storage o = _offerings[offeringId];
        OfferingParams storage p = o.params;
        if (state(offeringId) != State.OPEN || block.timestamp >= p.closesAt) revert NotOpen();

        uint256 total = subscriptionOf[offeringId][msg.sender] + amount;
        if (amount == 0 || total < p.minTicket) revert BelowMinimumTicket();
        IIdentityRegistry registry = IPrecursorShareToken(p.shareToken).identityRegistry();
        for (uint256 i; i < p.requiredClaims.length; ++i) {
            if (!registry.hasValidClaim(msg.sender, p.requiredClaims[i])) {
                revert MissingClaim(p.requiredClaims[i]);
            }
        }
        (bool ok, bytes32 code) =
            IPrecursorShareToken(p.shareToken).canTransfer(address(0), msg.sender, _sharesFor(total, p.pricePerShare));
        if (!ok) revert IPrecursorShareToken.TransferNotAllowed(code);

        if (subscriptionOf[offeringId][msg.sender] == 0) {
            if (_subscribers[offeringId].length >= MAX_SUBSCRIBERS) revert TooManySubscribers();
            _subscribers[offeringId].push(msg.sender);
        }
        subscriptionOf[offeringId][msg.sender] = total;
        o.raised += amount;
        IERC20(p.stablecoin).safeTransferFrom(msg.sender, address(this), amount);
        emit Subscribed(offeringId, msg.sender, amount);
    }

    /// @notice Settles an offering. Anyone may call it after `closesAt`; the company may close early once
    ///         `maxRaise` has been reached.
    function close(uint256 offeringId) external nonReentrant {
        Offering storage o = _offerings[offeringId];
        OfferingParams storage p = o.params;
        if (o.closed || o.failed) revert AlreadyFinal();
        bool ended = block.timestamp >= p.closesAt;
        bool earlyClose = hasRole(Roles.ISSUER_ADMIN, msg.sender) && o.raised >= p.maxRaise;
        if (!ended && !earlyClose) revert CannotClose();

        if (o.raised < p.minRaise || o.raised == 0) {
            o.failed = true;
            emit OfferingFailed(offeringId);
            return;
        }

        o.closed = true;
        IPrecursorShareToken shareToken = IPrecursorShareToken(p.shareToken);
        uint256 target = o.raised > p.maxRaise ? p.maxRaise : o.raised;
        address[] storage subs = _subscribers[offeringId];
        uint256 acceptedTotal;
        uint256 sharesTotal;

        for (uint256 i; i < subs.length; ++i) {
            address investor = subs[i];
            uint256 subscribed = subscriptionOf[offeringId][investor];
            uint256 allocation = (subscribed * target) / o.raised;
            uint256 shares = _sharesFor(allocation, p.pricePerShare);
            if (shares != 0) {
                (bool ok,) = shareToken.canTransfer(address(0), investor, shares);
                if (ok) {
                    // Charge only for whole raw units actually minted.
                    allocation = (shares * p.pricePerShare) / 1e18;
                    shareToken.mint(investor, shares, bytes32(offeringId));
                    acceptedTotal += allocation;
                    sharesTotal += shares;
                } else {
                    allocation = 0;
                }
            } else {
                allocation = 0;
            }
            refundableOf[offeringId][investor] = subscribed - allocation;
        }

        o.accepted = acceptedTotal;
        o.sharesIssued = sharesTotal;

        uint256 fee = (acceptedTotal * feeBps) / 10_000;
        IERC20 stable = IERC20(p.stablecoin);
        if (fee != 0) stable.safeTransfer(feeRecipient, fee);
        stable.safeTransfer(p.treasury, acceptedTotal - fee);

        _publishValuation(p);
        emit OfferingClosed(offeringId, acceptedTotal, sharesTotal);
    }

    function refund(uint256 offeringId) external nonReentrant {
        Offering storage o = _offerings[offeringId];
        uint256 amount;
        if (o.failed) {
            amount = subscriptionOf[offeringId][msg.sender];
            subscriptionOf[offeringId][msg.sender] = 0;
        } else if (o.closed) {
            amount = refundableOf[offeringId][msg.sender];
            refundableOf[offeringId][msg.sender] = 0;
        }
        if (amount == 0) revert NothingToRefund();
        IERC20(o.params.stablecoin).safeTransfer(msg.sender, amount);
        emit Refunded(offeringId, msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    function state(uint256 offeringId) public view returns (State) {
        Offering storage o = _offerings[offeringId];
        if (o.failed) return State.FAILED;
        if (o.closed) return State.CLOSED;
        if (block.timestamp < o.params.opensAt) return State.SCHEDULED;
        // Stays OPEN after closesAt until someone calls close(); subscribe() checks the time separately.
        return State.OPEN;
    }

    function offering(uint256 offeringId) external view returns (Offering memory) {
        return _offerings[offeringId];
    }

    function offeringCount() external view returns (uint256) {
        return _offerings.length;
    }

    function subscribers(uint256 offeringId) external view returns (address[] memory) {
        return _subscribers[offeringId];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    function _sharesFor(uint256 amount, uint256 pricePerShare) private pure returns (uint256) {
        return (amount * 1e18) / pricePerShare;
    }

    function _publishValuation(OfferingParams storage p) private {
        address oracle = factory.shareClassOf(p.shareToken).valuationOracle;
        uint8 stableDecimals = IERC20Metadata(p.stablecoin).decimals();
        int256 price = int256(_toOracleUnits(p.pricePerShare, stableDecimals));
        // A valuation that cannot be published (for example while the token is paused) must not block settlement.
        try IValuationOracle(oracle)
            .publish(
                price, uint8(IValuationOracle.Source.PRICED_ROUND), uint64(block.timestamp), bytes32(p.documentId)
            ) {}
            catch {}
    }

    function _toOracleUnits(uint256 amount, uint8 stableDecimals) private pure returns (uint256) {
        if (stableDecimals == 8) return amount;
        if (stableDecimals < 8) return amount * 10 ** (8 - stableDecimals);
        return amount / 10 ** (stableDecimals - 8);
    }

    function _setFee(address recipient, uint16 bps) private {
        if (bps > MAX_FEE_BPS || (bps != 0 && recipient == address(0))) revert InvalidParams();
        feeRecipient = recipient;
        feeBps = bps;
        emit FeeUpdated(recipient, bps);
    }
}
