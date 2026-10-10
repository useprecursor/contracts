// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPrecursorShareToken} from "./interfaces/IPrecursorShareToken.sol";
import {IPrecursorFactory} from "./interfaces/IPrecursorFactory.sol";
import {IValuationOracle} from "./interfaces/IValuationOracle.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title LiquidityWindow
/// @notice Company-run, time-boxed liquidity events for a share class.
///         - AUCTION mode: sellers and buyers both name a limit price. After close, one uniform clearing price is
///           chosen to maximise matched volume and every fill settles at that price.
///         - TENDER mode: the price is fixed up front. Sellers tender quantities and buyers commit at that price;
///           the oversubscribed side is filled pro-rata.
///         Sellers' tokens and buyers' stablecoin are escrowed here while the window is open, and `clear` settles
///         everything atomically: tokens to buyers, stablecoin to sellers, the rest back to its owners.
/// @dev Clearing price selection (AUCTION): evaluate every limit price; keep those with the highest matched volume;
///      pick the one nearest the latest Reference Valuation (or the midpoint of the best ask and best bid if there is
///      none); raise it to `reservePrice` if below. Fills go by price priority, pro-rata within the marginal price
///      level. Rounding always favours the contract: buyers pay rounded up, sellers receive rounded down, and the
///      dust goes to the fee recipient.
///
///      Right of first refusal: if `rofrHolder` is set, they may commit to buy at the clearing price during
///      `rofrPeriod` after close. Their quantity is filled first and displaces other buyers; it never adds volume.
///
///      Orders are bounded (MAX_ORDERS) so `clear` fits in one transaction. If a buyer stops passing the share class
///      rules after placing a bid, `clear` refunds that bid rather than reverting. The company can also remove a
///      problem order between close and clearing.
contract LiquidityWindow is AccessControl, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant SELL = 0;
    uint8 public constant BUY = 1;
    uint8 public constant AUCTION = 0;
    uint8 public constant TENDER = 1;
    uint256 public constant MAX_ORDERS = 200;
    uint16 public constant MAX_FEE_BPS = 250;

    struct WindowParams {
        address shareToken;
        uint8 mode;
        uint64 opensAt;
        uint64 closesAt;
        address stablecoin;
        uint256 reservePrice; // stablecoin units per whole share
        uint256 tenderPrice; // TENDER mode only
        uint256 maxVolume; // raw token units, 0 = unlimited
        uint256 perSellerCap; // raw token units, 0 = unlimited
        address rofrHolder; // zero = no right of first refusal
        uint32 rofrPeriod;
        bytes32[] sellerClaims;
        bytes32[] buyerClaims;
    }

    struct Order {
        address owner;
        uint8 side;
        bool active;
        uint256 quantity;
        uint256 limitPrice;
        uint256 locked; // stablecoin escrowed for a bid
        uint256 filled;
    }

    struct Window {
        WindowParams params;
        bool cleared;
        bool cancelled;
        uint256 clearingPrice;
        uint256 volume;
        uint256 rofrQuantity;
        uint256 rofrLocked;
        uint256 rofrFilled;
    }

    event WindowOpened(uint256 indexed windowId, uint64 opensAt, uint64 closesAt);
    event OrderPlaced(
        uint256 indexed windowId, uint256 indexed orderId, uint8 side, uint256 quantity, uint256 limitPrice
    );
    event OrderCancelled(uint256 indexed windowId, uint256 indexed orderId);
    event RofrExercised(uint256 indexed windowId, address indexed holder, uint256 quantity, uint256 price);
    event WindowCleared(uint256 indexed windowId, uint256 clearingPrice, uint256 volume);
    event WindowCancelled(uint256 indexed windowId);
    event FeesUpdated(address recipient, uint16 sellerFeeBps, uint16 buyerFeeBps);
    event DeliveryDeferred(address indexed shareToken, address indexed owner, uint256 amount);
    event DeferredClaimed(address indexed shareToken, address indexed owner, uint256 amount);

    error InvalidParams();
    error NotCompanyToken();
    error NotOpen();
    error NotOwner();
    error TooManyOrders();
    error OverSellerCap();
    error MissingClaim(bytes32 topic);
    error NotInRofrPeriod();
    error AlreadyFinal();
    error TooEarly();
    error NoMarket();

    bytes32 public companyId;
    IPrecursorFactory public factory;
    address public feeRecipient;
    uint16 public sellerFeeBps;
    uint16 public buyerFeeBps;

    Window[] private _windows;
    mapping(uint256 => Order[]) private _orders;
    mapping(uint256 => mapping(address => uint256)) public sellerQuantity;
    /// @notice Tokens owed to an owner whose delivery failed the share class rules (for example an expired claim).
    mapping(address => mapping(address => uint256)) public deferredTokens;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        bytes32 companyId_,
        address factory_,
        address admin,
        address issuerAdmin,
        address feeRecipient_,
        uint16 sellerFeeBps_,
        uint16 buyerFeeBps_
    ) external initializer {
        companyId = companyId_;
        factory = IPrecursorFactory(factory_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.ISSUER_ADMIN, issuerAdmin);
        _setFees(feeRecipient_, sellerFeeBps_, buyerFeeBps_);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Company
    // ---------------------------------------------------------------------------------------------------------------

    function openWindow(WindowParams calldata p) external onlyRole(Roles.ISSUER_ADMIN) returns (uint256 windowId) {
        if (factory.shareClassOf(p.shareToken).companyId != companyId) revert NotCompanyToken();
        if (p.mode > TENDER || p.closesAt <= p.opensAt || p.closesAt <= block.timestamp || p.stablecoin == address(0)) {
            revert InvalidParams();
        }
        if (p.mode == TENDER && p.tenderPrice == 0) revert InvalidParams();
        if (p.rofrHolder == address(0) && p.rofrPeriod != 0) revert InvalidParams();

        _windows.push();
        windowId = _windows.length - 1;
        _windows[windowId].params = p;
        emit WindowOpened(windowId, p.opensAt, p.closesAt);
    }

    /// @notice Cancels a window before it clears and returns every escrowed token and stablecoin.
    function cancelWindow(uint256 windowId) external onlyRole(Roles.ISSUER_ADMIN) nonReentrant {
        Window storage w = _windows[windowId];
        if (w.cleared || w.cancelled) revert AlreadyFinal();
        w.cancelled = true;
        Order[] storage list = _orders[windowId];
        for (uint256 i; i < list.length; ++i) {
            if (list[i].active) _refund(w, list[i]);
        }
        if (w.rofrLocked != 0) {
            uint256 amount = w.rofrLocked;
            w.rofrLocked = 0;
            IERC20(w.params.stablecoin).safeTransfer(w.params.rofrHolder, amount);
        }
        emit WindowCancelled(windowId);
    }

    /// @notice Removes one order between close and clearing, for example one that would block settlement.
    function removeOrder(uint256 windowId, uint256 orderId) external onlyRole(Roles.ISSUER_ADMIN) nonReentrant {
        Window storage w = _windows[windowId];
        if (w.cleared || w.cancelled) revert AlreadyFinal();
        if (block.timestamp < w.params.closesAt) revert TooEarly();
        Order storage o = _orders[windowId][orderId];
        if (!o.active) revert AlreadyFinal();
        _refund(w, o);
        emit OrderCancelled(windowId, orderId);
    }

    function setFees(address recipient, uint16 sellerBps, uint16 buyerBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFees(recipient, sellerBps, buyerBps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Participants
    // ---------------------------------------------------------------------------------------------------------------

    function placeOrder(uint256 windowId, uint8 side, uint256 quantity, uint256 limitPrice)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        Window storage w = _windows[windowId];
        WindowParams storage p = w.params;
        if (w.cleared || w.cancelled || block.timestamp < p.opensAt || block.timestamp >= p.closesAt) revert NotOpen();
        if (quantity == 0 || side > BUY) revert InvalidParams();
        if (_orders[windowId].length >= MAX_ORDERS) revert TooManyOrders();
        if (p.mode == TENDER) limitPrice = p.tenderPrice;
        else if (limitPrice == 0) revert InvalidParams();

        IPrecursorShareToken token = IPrecursorShareToken(p.shareToken);
        _requireClaims(token, side == SELL ? p.sellerClaims : p.buyerClaims);

        uint256 locked;
        if (side == SELL) {
            uint256 total = sellerQuantity[windowId][msg.sender] + quantity;
            if (p.perSellerCap != 0 && total > p.perSellerCap) revert OverSellerCap();
            sellerQuantity[windowId][msg.sender] = total;
            // The token runs the seller-side rules (holding periods, vesting, freezes) on this escrow transfer.
            IERC20(address(token)).safeTransferFrom(msg.sender, address(this), quantity);
        } else {
            (bool ok, bytes32 code) = token.canTransfer(address(this), msg.sender, quantity);
            if (!ok) revert IPrecursorShareToken.TransferNotAllowed(code);
            locked = _buyerTotal(quantity, limitPrice);
            IERC20(p.stablecoin).safeTransferFrom(msg.sender, address(this), locked);
        }

        _orders[windowId].push(
            Order({
                owner: msg.sender,
                side: side,
                active: true,
                quantity: quantity,
                limitPrice: limitPrice,
                locked: locked,
                filled: 0
            })
        );
        orderId = _orders[windowId].length - 1;
        emit OrderPlaced(windowId, orderId, side, quantity, limitPrice);
    }

    function cancelOrder(uint256 windowId, uint256 orderId) external nonReentrant {
        Window storage w = _windows[windowId];
        if (w.cleared || w.cancelled || block.timestamp >= w.params.closesAt) revert NotOpen();
        Order storage o = _orders[windowId][orderId];
        if (o.owner != msg.sender) revert NotOwner();
        if (!o.active) revert AlreadyFinal();
        if (o.side == SELL) sellerQuantity[windowId][msg.sender] -= o.quantity;
        _refund(w, o);
        emit OrderCancelled(windowId, orderId);
    }

    /// @notice The right holder commits to buy up to `quantity` at the clearing price, ahead of other buyers.
    function exerciseRofr(uint256 windowId, uint256 quantity) external nonReentrant {
        Window storage w = _windows[windowId];
        WindowParams storage p = w.params;
        if (msg.sender != p.rofrHolder || w.cleared || w.cancelled || w.rofrQuantity != 0 || quantity == 0) {
            revert NotInRofrPeriod();
        }
        if (block.timestamp < p.closesAt || block.timestamp >= uint256(p.closesAt) + p.rofrPeriod) {
            revert NotInRofrPeriod();
        }
        (uint256 price,) = previewClearing(windowId);
        if (price == 0) revert NoMarket();
        (bool ok, bytes32 code) = IPrecursorShareToken(p.shareToken).canTransfer(address(this), msg.sender, quantity);
        if (!ok) revert IPrecursorShareToken.TransferNotAllowed(code);

        uint256 locked = _buyerTotal(quantity, price);
        w.rofrQuantity = quantity;
        w.rofrLocked = locked;
        IERC20(p.stablecoin).safeTransferFrom(msg.sender, address(this), locked);
        emit RofrExercised(windowId, msg.sender, quantity, price);
    }

    /// @notice Claims tokens whose delivery was deferred because the owner failed a rule at the time.
    function claimDeferred(address shareToken) external nonReentrant {
        uint256 amount = deferredTokens[shareToken][msg.sender];
        if (amount == 0) revert AlreadyFinal();
        deferredTokens[shareToken][msg.sender] = 0;
        IERC20(shareToken).safeTransfer(msg.sender, amount);
        emit DeferredClaimed(shareToken, msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Clearing
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The price and volume `clear` would produce right now (before the right of first refusal).
    function previewClearing(uint256 windowId) public view returns (uint256 price, uint256 volume) {
        Book memory book = _loadBook(windowId);
        (price, volume) = _clearingPrice(_windows[windowId].params, book);
    }

    /// @notice Settles the window. Anyone may call it once the window and any ROFR period have ended.
    function clear(uint256 windowId) external nonReentrant {
        Window storage w = _windows[windowId];
        WindowParams storage p = w.params;
        if (w.cleared || w.cancelled) revert AlreadyFinal();
        if (block.timestamp < uint256(p.closesAt) + p.rofrPeriod) revert TooEarly();
        w.cleared = true;

        Book memory book = _loadBook(windowId);
        (uint256 price, uint256 volume) = _clearingPrice(p, book);
        if (p.maxVolume != 0 && volume > p.maxVolume) volume = p.maxVolume;
        uint256 rofrFill = Math.min(w.rofrQuantity, volume);
        // The holder's deposit was sized at the preview price. Never fill more than it pays for.
        while (rofrFill != 0 && _buyerTotal(rofrFill, price) > w.rofrLocked) {
            rofrFill = Math.mulDiv(rofrFill, w.rofrLocked, _buyerTotal(rofrFill, price));
        }

        uint256[] memory askFills = _allocate(book, SELL, price, volume, p.mode == TENDER);
        uint256[] memory bidFills = _allocate(book, BUY, price, volume - rofrFill, p.mode == TENDER);

        Settlement memory s;
        Order[] storage list = _orders[windowId];
        for (uint256 i; i < list.length; ++i) {
            Order storage o = list[i];
            if (!o.active) continue;
            o.active = false;
            if (o.side == SELL) _settleAsk(p, o, askFills[i], price, s);
            else _settleBid(p, o, bidFills[i], price, s);
        }
        if (w.rofrQuantity != 0) {
            w.rofrFilled = rofrFill;
            _settleRofr(w, rofrFill, price, s);
        }

        // Fees plus rounding dust: buyers pay rounded up, sellers receive rounded down.
        uint256 toFeeRecipient = s.buyerPaid - s.sellerReceived;
        if (toFeeRecipient != 0) IERC20(p.stablecoin).safeTransfer(feeRecipient, toFeeRecipient);

        w.clearingPrice = price;
        w.volume = volume;
        if (volume != 0) _publishValuation(p, price);
        emit WindowCleared(windowId, price, volume);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    function window(uint256 windowId) external view returns (Window memory) {
        return _windows[windowId];
    }

    function windowCount() external view returns (uint256) {
        return _windows.length;
    }

    function orders(uint256 windowId) external view returns (Order[] memory) {
        return _orders[windowId];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals: book and clearing
    // ---------------------------------------------------------------------------------------------------------------

    struct Book {
        uint256 n;
        uint8[] side;
        uint256[] qty;
        uint256[] limit;
        bool[] live;
    }

    struct Settlement {
        uint256 buyerPaid; // stablecoin taken from buyers for fills, including buyer fees
        uint256 sellerReceived; // stablecoin paid to sellers
        uint256 fees;
    }

    function _loadBook(uint256 windowId) private view returns (Book memory b) {
        Order[] storage orders_ = _orders[windowId];
        address token = _windows[windowId].params.shareToken;
        uint256 n = orders_.length;
        b.n = n;
        b.side = new uint8[](n);
        b.qty = new uint256[](n);
        b.limit = new uint256[](n);
        b.live = new bool[](n);
        for (uint256 i; i < n; ++i) {
            Order storage o = orders_[i];
            b.side[i] = o.side;
            b.qty[i] = o.quantity;
            b.limit[i] = o.limitPrice;
            if (!o.active) continue;
            if (o.side == BUY) {
                (bool ok,) = IPrecursorShareToken(token).canTransfer(address(this), o.owner, o.quantity);
                b.live[i] = ok;
            } else {
                b.live[i] = true;
            }
        }
    }

    function _clearingPrice(WindowParams storage p, Book memory b)
        private
        view
        returns (uint256 price, uint256 volume)
    {
        if (p.mode == TENDER) {
            uint256 supply;
            uint256 demand;
            for (uint256 i; i < b.n; ++i) {
                if (!b.live[i]) continue;
                if (b.side[i] == SELL) supply += b.qty[i];
                else demand += b.qty[i];
            }
            volume = Math.min(supply, demand);
            return (volume == 0 ? 0 : p.tenderPrice, volume);
        }

        uint256 bestVolume;
        uint256 lo = type(uint256).max;
        uint256 hi;
        uint256 minAsk = type(uint256).max;
        uint256 maxBid;
        for (uint256 i; i < b.n; ++i) {
            if (!b.live[i]) continue;
            if (b.side[i] == SELL && b.limit[i] < minAsk) minAsk = b.limit[i];
            if (b.side[i] == BUY && b.limit[i] > maxBid) maxBid = b.limit[i];
            uint256 v = _volumeAt(b, b.limit[i]);
            if (v > bestVolume) {
                bestVolume = v;
                lo = b.limit[i];
                hi = b.limit[i];
            } else if (v == bestVolume && v != 0) {
                if (b.limit[i] < lo) lo = b.limit[i];
                if (b.limit[i] > hi) hi = b.limit[i];
            }
        }
        if (bestVolume == 0) return (0, 0);

        uint256 ref = _referencePrice(p);
        if (ref == 0) ref = (minAsk + maxBid) / 2;
        // Pick the max-volume price nearest the reference.
        if (ref >= lo && ref <= hi && _volumeAt(b, ref) == bestVolume) {
            price = ref;
        } else {
            price = lo;
            uint256 bestDistance = _distance(lo, ref);
            for (uint256 i; i < b.n; ++i) {
                if (!b.live[i] || _volumeAt(b, b.limit[i]) != bestVolume) continue;
                uint256 d = _distance(b.limit[i], ref);
                if (d < bestDistance) {
                    bestDistance = d;
                    price = b.limit[i];
                }
            }
        }
        if (price < p.reservePrice) price = p.reservePrice;
        volume = _volumeAt(b, price);
        if (volume == 0) price = 0;
    }

    function _volumeAt(Book memory b, uint256 price) private pure returns (uint256) {
        uint256 supply;
        uint256 demand;
        for (uint256 i; i < b.n; ++i) {
            if (!b.live[i]) continue;
            if (b.side[i] == SELL && b.limit[i] <= price) supply += b.qty[i];
            else if (b.side[i] == BUY && b.limit[i] >= price) demand += b.qty[i];
        }
        return Math.min(supply, demand);
    }

    /// @dev Fills `volume` on one side by price priority, pro-rata within the marginal price level.
    function _allocate(Book memory b, uint8 side, uint256 price, uint256 volume, bool tender)
        private
        pure
        returns (uint256[] memory fills)
    {
        fills = new uint256[](b.n);
        if (price == 0 || volume == 0) return fills;
        bool[] memory done = new bool[](b.n);
        uint256 remaining = volume;

        while (remaining != 0) {
            // Best remaining level: lowest ask, highest bid. Every order is at one level in a tender.
            bool found;
            uint256 level;
            for (uint256 i; i < b.n; ++i) {
                if (done[i] || !_eligible(b, i, side, price, tender)) continue;
                if (!found || (side == SELL ? b.limit[i] < level : b.limit[i] > level)) {
                    level = b.limit[i];
                    found = true;
                }
            }
            if (!found) break;

            uint256 levelQty;
            for (uint256 i; i < b.n; ++i) {
                if (!done[i] && _eligible(b, i, side, price, tender) && (tender || b.limit[i] == level)) {
                    levelQty += b.qty[i];
                }
            }

            if (levelQty <= remaining) {
                for (uint256 i; i < b.n; ++i) {
                    if (!done[i] && _eligible(b, i, side, price, tender) && (tender || b.limit[i] == level)) {
                        fills[i] = b.qty[i];
                        done[i] = true;
                    }
                }
                remaining -= levelQty;
            } else {
                uint256 allocated;
                for (uint256 i; i < b.n; ++i) {
                    if (!done[i] && _eligible(b, i, side, price, tender) && (tender || b.limit[i] == level)) {
                        fills[i] = (b.qty[i] * remaining) / levelQty;
                        allocated += fills[i];
                        done[i] = true;
                    }
                }
                // Hand out rounding remainder one unit at a time to orders with room.
                uint256 leftover = remaining - allocated;
                for (uint256 i; i < b.n && leftover != 0; ++i) {
                    if (
                        done[i] && fills[i] < b.qty[i] && _eligible(b, i, side, price, tender)
                            && (tender || b.limit[i] == level)
                    ) {
                        uint256 room = b.qty[i] - fills[i];
                        uint256 add = room < leftover ? room : leftover;
                        fills[i] += add;
                        leftover -= add;
                    }
                }
                remaining = 0;
            }
        }
    }

    function _eligible(Book memory b, uint256 i, uint8 side, uint256 price, bool tender) private pure returns (bool) {
        if (!b.live[i] || b.side[i] != side) return false;
        if (tender) return true;
        return side == SELL ? b.limit[i] <= price : b.limit[i] >= price;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals: settlement
    // ---------------------------------------------------------------------------------------------------------------

    function _settleAsk(WindowParams storage p, Order storage o, uint256 fill, uint256 price, Settlement memory s)
        private
    {
        o.filled = fill;
        if (fill != 0) {
            uint256 gross = (fill * price) / 1e18;
            uint256 fee = (gross * sellerFeeBps) / 10_000;
            s.fees += fee;
            s.sellerReceived += gross - fee;
            IERC20(p.stablecoin).safeTransfer(o.owner, gross - fee);
        }
        if (o.quantity > fill) _deliver(p.shareToken, o.owner, o.quantity - fill);
    }

    function _settleBid(WindowParams storage p, Order storage o, uint256 fill, uint256 price, Settlement memory s)
        private
    {
        o.filled = fill;
        uint256 charged;
        if (fill != 0) {
            charged = _buyerTotal(fill, price);
            s.fees += charged - Math.mulDiv(fill, price, 1e18, Math.Rounding.Ceil);
            s.buyerPaid += charged;
            _deliver(p.shareToken, o.owner, fill);
        }
        if (o.locked > charged) IERC20(p.stablecoin).safeTransfer(o.owner, o.locked - charged);
    }

    function _settleRofr(Window storage w, uint256 fill, uint256 price, Settlement memory s) private {
        WindowParams storage p = w.params;
        uint256 charged;
        if (fill != 0) {
            charged = _buyerTotal(fill, price);
            s.fees += charged - Math.mulDiv(fill, price, 1e18, Math.Rounding.Ceil);
            s.buyerPaid += charged;
            _deliver(p.shareToken, p.rofrHolder, fill);
        }
        uint256 locked = w.rofrLocked;
        w.rofrLocked = 0;
        if (locked > charged) IERC20(p.stablecoin).safeTransfer(p.rofrHolder, locked - charged);
    }

    function _refund(Window storage w, Order storage o) private {
        o.active = false;
        if (o.side == SELL) _deliver(w.params.shareToken, o.owner, o.quantity);
        else IERC20(w.params.stablecoin).safeTransfer(o.owner, o.locked);
    }

    /// @dev Token deliveries never revert settlement. If the recipient fails the share class rules, the tokens stay
    ///      here, owed to them, and they can claim once they pass again.
    function _deliver(address shareToken, address to, uint256 amount) private {
        try IERC20(shareToken).transfer(to, amount) returns (bool ok) {
            if (ok) return;
        } catch {}
        deferredTokens[shareToken][to] += amount;
        emit DeliveryDeferred(shareToken, to, amount);
    }

    /// @dev Stablecoin a buyer pays for `quantity` at `price`, rounded up, plus the buyer fee (also rounded up).
    function _buyerTotal(uint256 quantity, uint256 price) private view returns (uint256) {
        uint256 gross = Math.mulDiv(quantity, price, 1e18, Math.Rounding.Ceil);
        return gross + Math.mulDiv(gross, buyerFeeBps, 10_000, Math.Rounding.Ceil);
    }

    function _requireClaims(IPrecursorShareToken token, bytes32[] storage topics) private view {
        for (uint256 i; i < topics.length; ++i) {
            if (!token.identityRegistry().hasValidClaim(msg.sender, topics[i])) revert MissingClaim(topics[i]);
        }
    }

    function _referencePrice(WindowParams storage p) private view returns (uint256) {
        address oracle = factory.shareClassOf(p.shareToken).valuationOracle;
        try IValuationOracle(oracle).latestValuation() returns (int256 price, uint8, uint64, bytes32) {
            if (price <= 0) return 0;
            return _fromOracleUnits(uint256(price), IERC20Metadata(p.stablecoin).decimals());
        } catch {
            return 0;
        }
    }

    function _publishValuation(WindowParams storage p, uint256 price) private {
        address oracle = factory.shareClassOf(p.shareToken).valuationOracle;
        uint256 oraclePrice = _toOracleUnits(price, IERC20Metadata(p.stablecoin).decimals());
        if (oraclePrice == 0) return;
        try IValuationOracle(oracle)
            .publish(
                int256(oraclePrice), uint8(IValuationOracle.Source.WINDOW_CLEARING), uint64(block.timestamp), bytes32(0)
            ) {}
            catch {}
    }

    function _toOracleUnits(uint256 amount, uint8 d) private pure returns (uint256) {
        if (d == 8) return amount;
        return d < 8 ? amount * 10 ** (8 - d) : amount / 10 ** (d - 8);
    }

    function _fromOracleUnits(uint256 amount, uint8 d) private pure returns (uint256) {
        if (d == 8) return amount;
        return d < 8 ? amount / 10 ** (8 - d) : amount * 10 ** (d - 8);
    }

    function _distance(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _setFees(address recipient, uint16 sellerBps, uint16 buyerBps) private {
        if (sellerBps > MAX_FEE_BPS || buyerBps > MAX_FEE_BPS) revert InvalidParams();
        if ((sellerBps != 0 || buyerBps != 0) && recipient == address(0)) revert InvalidParams();
        feeRecipient = recipient;
        sellerFeeBps = sellerBps;
        buyerFeeBps = buyerBps;
        emit FeesUpdated(recipient, sellerBps, buyerBps);
    }
}
