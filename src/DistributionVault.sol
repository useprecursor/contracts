// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPrecursorShareToken} from "./interfaces/IPrecursorShareToken.sol";
import {IPrecursorFactory} from "./interfaces/IPrecursorFactory.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title DistributionVault
/// @notice Pays dividends and other proceeds to the holders of a share class. The company funds a distribution with
///         a record block; each holder's entitlement is their balance at that block as a share of the eligible
///         supply. Holders (or anyone on their behalf) pull their entitlement whenever they like.
/// @dev Raw balances are used, so the display multiplier does not affect entitlements within a class. Frozen tokens
///      still earn distributions. Excluded accounts (for example treasury shares and escrow contracts) are removed
///      from the eligible supply and cannot claim. If a claim deadline is set it must be at least 12 months out;
///      after it passes the company can sweep what is left back to its treasury.
contract DistributionVault is AccessControl, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_CLAIM_WINDOW = 365 days;
    uint256 public constant MAX_EXCLUDED = 20;

    struct Distribution {
        address shareToken;
        address asset;
        uint256 amount;
        uint48 recordBlock;
        uint64 claimDeadline; // 0 = no deadline
        uint256 eligibleSupply;
        uint256 claimed;
        bool swept;
    }

    event DistributionFunded(uint256 indexed distributionId, address asset, uint256 amount, uint256 recordBlock);
    event DistributionClaimed(uint256 indexed distributionId, address indexed holder, uint256 amount);
    event DistributionSwept(uint256 indexed distributionId, uint256 amount);

    error NotCompanyToken();
    error InvalidParams();
    error NothingToClaim();
    error DeadlinePassed();
    error NotSweepable();
    error UnknownDistribution();

    bytes32 public companyId;
    IPrecursorFactory public factory;
    address public treasury;

    Distribution[] private _distributions;
    mapping(uint256 => mapping(address => bool)) public excluded;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    constructor() {
        _disableInitializers();
    }

    function initialize(bytes32 companyId_, address factory_, address admin, address issuerAdmin, address treasury_)
        external
        initializer
    {
        companyId = companyId_;
        factory = IPrecursorFactory(factory_);
        treasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.ISSUER_ADMIN, issuerAdmin);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert InvalidParams();
        treasury = treasury_;
    }

    function fund(
        address shareToken,
        address asset,
        uint256 amount,
        uint48 recordBlock,
        uint64 claimDeadline,
        address[] calldata excludedAccounts
    ) external onlyRole(Roles.ISSUER_ADMIN) nonReentrant returns (uint256 distributionId) {
        if (factory.shareClassOf(shareToken).companyId != companyId) revert NotCompanyToken();
        if (amount == 0 || asset == address(0) || excludedAccounts.length > MAX_EXCLUDED) revert InvalidParams();
        if (claimDeadline != 0 && claimDeadline < block.timestamp + MIN_CLAIM_WINDOW) revert InvalidParams();

        IPrecursorShareToken token = IPrecursorShareToken(shareToken);
        if (recordBlock >= token.clock()) revert InvalidParams();
        uint256 eligible = token.totalSupplyAt(recordBlock);

        distributionId = _distributions.length;
        for (uint256 i; i < excludedAccounts.length; ++i) {
            address a = excludedAccounts[i];
            if (excluded[distributionId][a]) continue;
            excluded[distributionId][a] = true;
            eligible -= token.balanceOfAt(a, recordBlock);
        }
        if (eligible == 0) revert InvalidParams();

        _distributions.push(
            Distribution({
                shareToken: shareToken,
                asset: asset,
                amount: amount,
                recordBlock: recordBlock,
                claimDeadline: claimDeadline,
                eligibleSupply: eligible,
                claimed: 0,
                swept: false
            })
        );
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit DistributionFunded(distributionId, asset, amount, recordBlock);
    }

    /// @notice What `holder` could claim right now. Zero once the claim deadline has passed.
    function claimable(uint256 distributionId, address holder) public view returns (uint256) {
        Distribution storage d = _get(distributionId);
        if (excluded[distributionId][holder] || hasClaimed[distributionId][holder] || d.swept) return 0;
        if (d.claimDeadline != 0 && block.timestamp >= d.claimDeadline) return 0;
        uint256 balance = IPrecursorShareToken(d.shareToken).balanceOfAt(holder, d.recordBlock);
        return (balance * d.amount) / d.eligibleSupply;
    }

    function claim(uint256 distributionId) external {
        _claim(distributionId, msg.sender);
    }

    /// @notice Claims several distributions in one transaction. Reverts if any of them has nothing to claim.
    function claimMany(uint256[] calldata distributionIds) external {
        for (uint256 i; i < distributionIds.length; ++i) {
            _claim(distributionIds[i], msg.sender);
        }
    }

    /// @notice Pays a holder's entitlement to the holder. Lets a relayer claim on someone's behalf.
    function claimFor(uint256 distributionId, address holder) external {
        _claim(distributionId, holder);
    }

    function sweep(uint256 distributionId) external onlyRole(Roles.ISSUER_ADMIN) nonReentrant {
        Distribution storage d = _get(distributionId);
        if (d.claimDeadline == 0 || block.timestamp < d.claimDeadline || d.swept) revert NotSweepable();
        d.swept = true;
        uint256 remaining = d.amount - d.claimed;
        if (remaining != 0) IERC20(d.asset).safeTransfer(treasury, remaining);
        emit DistributionSwept(distributionId, remaining);
    }

    function distribution(uint256 distributionId) external view returns (Distribution memory) {
        return _get(distributionId);
    }

    function distributionCount() external view returns (uint256) {
        return _distributions.length;
    }

    function _claim(uint256 distributionId, address holder) private nonReentrant {
        Distribution storage d = _get(distributionId);
        if (d.claimDeadline != 0 && block.timestamp >= d.claimDeadline) revert DeadlinePassed();
        uint256 amount = claimable(distributionId, holder);
        if (amount == 0) revert NothingToClaim();
        hasClaimed[distributionId][holder] = true;
        d.claimed += amount;
        IERC20(d.asset).safeTransfer(holder, amount);
        emit DistributionClaimed(distributionId, holder, amount);
    }

    function _get(uint256 distributionId) private view returns (Distribution storage) {
        if (distributionId >= _distributions.length) revert UnknownDistribution();
        return _distributions[distributionId];
    }
}
