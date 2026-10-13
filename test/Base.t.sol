// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PrecursorFactory} from "../src/PrecursorFactory.sol";
import {IPrecursorFactory} from "../src/interfaces/IPrecursorFactory.sol";
import {PrecursorShareToken} from "../src/PrecursorShareToken.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {TrustedVerifiers} from "../src/TrustedVerifiers.sol";
import {RuleEngine} from "../src/RuleEngine.sol";
import {OfferingVault} from "../src/OfferingVault.sol";
import {LiquidityWindow} from "../src/LiquidityWindow.sol";
import {RFQSettlement} from "../src/RFQSettlement.sol";
import {DistributionVault} from "../src/DistributionVault.sol";
import {Governance} from "../src/Governance.sol";
import {DisclosureRegistry} from "../src/DisclosureRegistry.sol";
import {IssuerTimelock} from "../src/IssuerTimelock.sol";
import {ValuationOracle} from "../src/ValuationOracle.sol";
import {PoolGate} from "../src/PoolGate.sol";
import {RegionModule} from "../src/modules/RegionModule.sol";
import {EligibilityModule} from "../src/modules/EligibilityModule.sol";
import {HoldingPeriodModule} from "../src/modules/HoldingPeriodModule.sol";
import {HolderCapModule} from "../src/modules/HolderCapModule.sol";
import {TransferWindowModule} from "../src/modules/TransferWindowModule.sol";
import {ROFRModule} from "../src/modules/ROFRModule.sol";
import {MaxOwnershipModule} from "../src/modules/MaxOwnershipModule.sol";
import {EmployeeVestingModule} from "../src/modules/EmployeeVestingModule.sol";
import {MockStablecoin} from "../src/mocks/MockStablecoin.sol";
import {Topics} from "../src/libraries/Topics.sol";

/// @dev Shared fixture: a factory with every implementation registered, one company ("NORTHWIND") with a 2-of-3
///      timelock, and helpers to verify holders, deploy share classes and run timelocked actions.
abstract contract Base is Test {
    bytes32 internal constant COMPANY = "NORTHWIND";
    bytes2 internal constant US = "US";
    bytes2 internal constant GB = "GB";
    bytes2 internal constant SG = "SG";
    bytes2 internal constant KP = "KP";

    PrecursorFactory internal factory;
    MockStablecoin internal usdg;
    IPrecursorFactory.CompanyContracts internal c;
    IdentityRegistry internal registry;
    IssuerTimelock internal timelock;
    OfferingVault internal offerings;
    LiquidityWindow internal windows;
    RFQSettlement internal rfq;
    DistributionVault internal distributions;
    Governance internal governance;
    DisclosureRegistry internal disclosures;

    address internal precursor = makeAddr("precursor");
    address internal issuerAdmin = makeAddr("issuerAdmin");
    address internal registrar = makeAddr("registrar");
    address internal operator = makeAddr("operator");
    address internal treasury = makeAddr("treasury");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal signer1 = makeAddr("signer1");
    address internal signer2 = makeAddr("signer2");
    address internal signer3 = makeAddr("signer3");

    address internal verifier;
    uint256 internal verifierKey;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    uint64 internal constant ONE_YEAR = 365 days;
    uint64 internal constant CLAIM_TTL = 5 * 365 days;
    uint256 internal constant T0 = 1_760_000_000;

    function setUp() public virtual {
        vm.warp(T0);
        vm.roll(1_000);
        (verifier, verifierKey) = makeAddrAndKey("verifier");
        usdg = new MockStablecoin();

        PrecursorFactory.Implementations memory impls = PrecursorFactory.Implementations({
            shareToken: address(new PrecursorShareToken()),
            identityRegistry: address(new IdentityRegistry()),
            trustedVerifiers: address(new TrustedVerifiers()),
            ruleEngine: address(new RuleEngine()),
            offeringVault: address(new OfferingVault()),
            liquidityWindow: address(new LiquidityWindow()),
            rfqSettlement: address(new RFQSettlement()),
            distributionVault: address(new DistributionVault()),
            governance: address(new Governance()),
            disclosureRegistry: address(new DisclosureRegistry()),
            issuerTimelock: address(new IssuerTimelock()),
            valuationOracle: address(new ValuationOracle()),
            poolGate: address(new PoolGate())
        });
        factory = new PrecursorFactory(
            precursor,
            impls,
            PrecursorFactory.Fees({recipient: feeRecipient, offeringBps: 100, sellerBps: 25, buyerBps: 25})
        );

        vm.startPrank(precursor);
        factory.setModuleImplementation("REGION", address(new RegionModule()));
        factory.setModuleImplementation("ELIGIBILITY", address(new EligibilityModule()));
        factory.setModuleImplementation("HOLDING_PERIOD", address(new HoldingPeriodModule()));
        factory.setModuleImplementation("HOLDER_CAP", address(new HolderCapModule()));
        factory.setModuleImplementation("TRANSFER_WINDOW", address(new TransferWindowModule()));
        factory.setModuleImplementation("ROFR", address(new ROFRModule()));
        factory.setModuleImplementation("MAX_OWNERSHIP", address(new MaxOwnershipModule()));
        factory.setModuleImplementation("EMPLOYEE_VESTING", address(new EmployeeVestingModule()));

        address[] memory verifiers = new address[](1);
        verifiers[0] = verifier;
        bytes32[][] memory topics = new bytes32[][](1);
        topics[0] = _allTopics();
        factory.setDefaultVerifiers(verifiers, topics);

        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;
        c = factory.deployCompany(
            PrecursorFactory.CompanyParams({
                companyId: COMPANY,
                issuerAdmin: issuerAdmin,
                registrar: registrar,
                operator: operator,
                treasury: treasury,
                timelockSigners: signers,
                timelockThreshold: 2,
                verifiers: new address[](0),
                verifierTopics: new bytes32[][](0)
            })
        );
        vm.stopPrank();

        registry = IdentityRegistry(c.identityRegistry);
        timelock = IssuerTimelock(payable(c.issuerTimelock));
        offerings = OfferingVault(c.offeringVault);
        windows = LiquidityWindow(c.liquidityWindow);
        rfq = RFQSettlement(c.rfqSettlement);
        distributions = DistributionVault(c.distributionVault);
        governance = Governance(c.governance);
        disclosures = DisclosureRegistry(c.disclosureRegistry);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Share classes
    // ---------------------------------------------------------------------------------------------------------------

    function _deployClass(bytes32 shareClass, PrecursorFactory.ModuleInit[] memory modules)
        internal
        returns (PrecursorShareToken token)
    {
        vm.prank(precursor);
        token = PrecursorShareToken(
            factory.deployShareClass(
                PrecursorFactory.ShareClassParams({
                    companyId: COMPANY,
                    shareClass: shareClass,
                    name: string(abi.encodePacked("Northwind ", shareClass)),
                    symbol: "NWD",
                    documentsRoot: keccak256("terms"),
                    modules: modules,
                    enablePools: false
                })
            )
        );
    }

    function _plainClass(bytes32 shareClass) internal returns (PrecursorShareToken) {
        return _deployClass(shareClass, new PrecursorFactory.ModuleInit[](0));
    }

    function _modules1(bytes32 id, bytes memory config) internal pure returns (PrecursorFactory.ModuleInit[] memory m) {
        m = new PrecursorFactory.ModuleInit[](1);
        m[0] = PrecursorFactory.ModuleInit({moduleId: id, config: config});
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Identities
    // ---------------------------------------------------------------------------------------------------------------

    function _verify(address wallet) internal {
        _verify(wallet, US, 1);
    }

    function _verify(address wallet, bytes2 region, uint8 tier) internal {
        vm.prank(operator);
        registry.registerIdentity(wallet, wallet);
        uint64 expiry = uint64(block.timestamp) + CLAIM_TTL;
        vm.startPrank(verifier);
        registry.addClaim(wallet, Topics.IDENTITY_VERIFIED, "", expiry, verifier, "");
        registry.addClaim(wallet, Topics.SCREENED, abi.encode(uint64(block.timestamp)), expiry, verifier, "");
        registry.addClaim(wallet, Topics.REGION, abi.encode(region), expiry, verifier, "");
        registry.addClaim(wallet, Topics.INVESTOR_ELIGIBLE, abi.encode(tier), expiry, verifier, "");
        vm.stopPrank();
    }

    function _addClaim(address identity, bytes32 topic, bytes memory data) internal {
        vm.prank(verifier);
        registry.addClaim(identity, topic, data, uint64(block.timestamp) + CLAIM_TTL, verifier, "");
    }

    function _mint(PrecursorShareToken token, address to, uint256 shares) internal {
        vm.prank(registrar);
        token.mint(to, shares, "cap-table");
    }

    function _allTopics() internal pure returns (bytes32[] memory t) {
        t = new bytes32[](6);
        t[0] = Topics.IDENTITY_VERIFIED;
        t[1] = Topics.INVESTOR_ELIGIBLE;
        t[2] = Topics.REGION;
        t[3] = Topics.EMPLOYEE_OF;
        t[4] = Topics.SCREENED;
        t[5] = Topics.VENUE;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Timelock
    // ---------------------------------------------------------------------------------------------------------------

    function _timelocked(address target, bytes memory data) internal returns (bytes memory) {
        bytes32 salt = keccak256(abi.encode(target, data, block.timestamp, gasleft()));
        vm.prank(signer1);
        bytes32 id = timelock.propose(target, 0, data, salt);
        vm.prank(signer2);
        timelock.approve(id);
        vm.warp(timelock.action(id).eta);
        return timelock.execute(id);
    }

    function _fund(address who, uint256 amount, address spender) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(spender, type(uint256).max);
    }

    function _usdg(uint256 whole) internal pure returns (uint256) {
        return whole * 1e6;
    }

    function _shares(uint256 whole) internal pure returns (uint256) {
        return whole * 1e18;
    }
}
