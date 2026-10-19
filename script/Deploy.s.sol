// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

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

/// @title Deploy
/// @notice Deploys Precursor to Robinhood Chain testnet (46630), or any EVM network, and writes every address to
///         `deployments/<chainId>.json`.
///
///         forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --verify
///
///         Environment (see .env.example):
///         - PRIVATE_KEY        deployer; also factory owner, fee recipient and default verifier unless overridden
///         - USDG               stablecoin address; leave blank off mainnet to deploy a 6-decimal test stablecoin
///         - FEE_RECIPIENT      optional
///         - DEFAULT_VERIFIER   optional; the identity provider key trusted for every claim topic
///         - DEPLOY_DEMO        optional, default true off mainnet: a demo company with two share classes, a
///                              verified deployer, a cap table and an open offering
contract Deploy is Script {
    uint256 internal constant MAINNET = 4663;
    bytes32 internal constant DEMO_COMPANY = "NORTHWIND_LABS";

    struct Deployed {
        PrecursorFactory factory;
        address stablecoin;
        IPrecursorFactory.CompanyContracts company;
        address common;
        address seriesB;
        uint256 offeringId;
    }

    function run() external returns (Deployed memory d) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        bool isMainnet = block.chainid == MAINNET;
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        address verifier = vm.envOr("DEFAULT_VERIFIER", deployer);
        bool demo = vm.envOr("DEPLOY_DEMO", !isMainnet);

        vm.startBroadcast(key);

        d.stablecoin = vm.envOr("USDG", address(0));
        if (d.stablecoin == address(0)) {
            require(!isMainnet, "USDG must be set on mainnet");
            d.stablecoin = address(new MockStablecoin());
        }

        d.factory = new PrecursorFactory(
            deployer,
            _implementations(),
            PrecursorFactory.Fees({recipient: feeRecipient, offeringBps: 100, sellerBps: 25, buyerBps: 25})
        );
        _registerModules(d.factory);

        address[] memory verifiers = new address[](1);
        verifiers[0] = verifier;
        bytes32[][] memory topics = new bytes32[][](1);
        topics[0] = _allTopics();
        d.factory.setDefaultVerifiers(verifiers, topics);

        if (demo) _demo(d, deployer, verifier == deployer);

        vm.stopBroadcast();
        _write(d);
    }

    // ---------------------------------------------------------------------------------------------------------------

    function _implementations() internal returns (PrecursorFactory.Implementations memory) {
        return PrecursorFactory.Implementations({
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
    }

    function _registerModules(PrecursorFactory f) internal {
        f.setModuleImplementation("REGION", address(new RegionModule()));
        f.setModuleImplementation("ELIGIBILITY", address(new EligibilityModule()));
        f.setModuleImplementation("HOLDING_PERIOD", address(new HoldingPeriodModule()));
        f.setModuleImplementation("HOLDER_CAP", address(new HolderCapModule()));
        f.setModuleImplementation("TRANSFER_WINDOW", address(new TransferWindowModule()));
        f.setModuleImplementation("ROFR", address(new ROFRModule()));
        f.setModuleImplementation("MAX_OWNERSHIP", address(new MaxOwnershipModule()));
        f.setModuleImplementation("EMPLOYEE_VESTING", address(new EmployeeVestingModule()));
    }

    /// @dev A self-contained demo: the deployer plays the company, registrar, operator and sole timelock signer,
    ///      so every flow can be exercised from one key. Real companies use separate keys and a multi-signer timelock.
    function _demo(Deployed memory d, address deployer, bool deployerIsVerifier) internal {
        address[] memory signers = new address[](1);
        signers[0] = deployer;
        d.company = d.factory
            .deployCompany(
                PrecursorFactory.CompanyParams({
                    companyId: DEMO_COMPANY,
                    issuerAdmin: deployer,
                    registrar: deployer,
                    operator: deployer,
                    treasury: deployer,
                    timelockSigners: signers,
                    timelockThreshold: 1,
                    verifiers: new address[](0),
                    verifierTopics: new bytes32[][](0)
                })
            );

        // Common: open to eligible investors and employees, sanctioned regions blocked, a holder cap, and a
        // 90-day lockup on shares bought in an offering.
        bytes2[] memory blocked = new bytes2[](4);
        blocked[0] = "KP";
        blocked[1] = "IR";
        blocked[2] = "CU";
        blocked[3] = "SY";
        bytes32[] memory sources = new bytes32[](1);
        sources[0] = "OFFERING";
        uint32[] memory periods = new uint32[](1);
        periods[0] = 90 days;
        address[] memory ops = new address[](2);
        ops[0] = d.company.offeringVault;
        ops[1] = d.company.liquidityWindow;
        bytes32[] memory opSources = new bytes32[](2);
        opSources[0] = "OFFERING";
        opSources[1] = "WINDOW";

        PrecursorFactory.ModuleInit[] memory commonRules = new PrecursorFactory.ModuleInit[](4);
        commonRules[0] = PrecursorFactory.ModuleInit("REGION", abi.encode(uint8(1), blocked));
        commonRules[1] = PrecursorFactory.ModuleInit("ELIGIBILITY", abi.encode(uint8(1), true));
        commonRules[2] = PrecursorFactory.ModuleInit("HOLDER_CAP", abi.encode(uint32(2_000)));
        commonRules[3] =
            PrecursorFactory.ModuleInit("HOLDING_PERIOD", abi.encode(uint32(0), sources, periods, ops, opSources));
        d.common = d.factory
            .deployShareClass(
                PrecursorFactory.ShareClassParams({
                    companyId: DEMO_COMPANY,
                    shareClass: "COMMON",
                    name: "Northwind Labs Common",
                    symbol: "NWL-C",
                    documentsRoot: keccak256("northwind-common-terms-v1"),
                    modules: commonRules,
                    enablePools: false
                })
            );

        // Series B Preferred: a higher eligibility tier and a 25% concentration cap on transfers.
        PrecursorFactory.ModuleInit[] memory prefRules = new PrecursorFactory.ModuleInit[](3);
        prefRules[0] = PrecursorFactory.ModuleInit("REGION", abi.encode(uint8(1), blocked));
        prefRules[1] = PrecursorFactory.ModuleInit("ELIGIBILITY", abi.encode(uint8(2), false));
        prefRules[2] = PrecursorFactory.ModuleInit("MAX_OWNERSHIP", abi.encode(uint16(2_500), false, new address[](0)));
        d.seriesB = d.factory
            .deployShareClass(
                PrecursorFactory.ShareClassParams({
                    companyId: DEMO_COMPANY,
                    shareClass: "SERIES_B",
                    name: "Northwind Labs Series B Preferred",
                    symbol: "NWL-B",
                    documentsRoot: keccak256("northwind-series-b-terms-v1"),
                    modules: prefRules,
                    enablePools: false
                })
            );

        if (!deployerIsVerifier) return; // claims must come from the configured verifier

        // Verify the deployer, import a small cap table, and open a Series B offering.
        IdentityRegistry registry = IdentityRegistry(d.company.identityRegistry);
        registry.registerIdentity(deployer, deployer);
        uint64 expiry = uint64(block.timestamp + 365 days);
        registry.addClaim(deployer, Topics.IDENTITY_VERIFIED, "", expiry, deployer, "");
        registry.addClaim(deployer, Topics.SCREENED, abi.encode(uint64(block.timestamp)), expiry, deployer, "");
        registry.addClaim(deployer, Topics.REGION, abi.encode(bytes2("US")), expiry, deployer, "");
        registry.addClaim(deployer, Topics.INVESTOR_ELIGIBLE, abi.encode(uint8(2)), expiry, deployer, "");

        PrecursorShareToken(d.common).mint(deployer, 1_000_000e18, "cap-table-import");
        PrecursorShareToken(d.seriesB).mint(deployer, 250_000e18, "cap-table-import");

        DisclosureRegistry(d.company.disclosureRegistry)
            .anchor("OFFERING_DOCUMENT", sha256("Northwind Labs Series B extension"), "https://useprecursor.xyz/demo");
        ValuationOracle(d.factory.shareClassOf(d.seriesB).valuationOracle)
            .publish(24e8, 1, uint64(block.timestamp), bytes32(0));

        bytes32[] memory claims = new bytes32[](1);
        claims[0] = Topics.INVESTOR_ELIGIBLE;
        d.offeringId = OfferingVault(d.company.offeringVault)
            .createOffering(
                OfferingVault.OfferingParams({
                shareToken: d.seriesB,
                pricePerShare: 25e6,
                minRaise: 50_000e6,
                maxRaise: 2_000_000e6,
                minTicket: 1_000e6,
                opensAt: uint64(block.timestamp),
                closesAt: uint64(block.timestamp + 30 days),
                stablecoin: d.stablecoin,
                requiredClaims: claims,
                treasury: deployer,
                documentId: 1
            })
            );
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

    function _write(Deployed memory d) internal {
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "factory", address(d.factory));
        string memory json = vm.serializeAddress(root, "stablecoin", d.stablecoin);

        if (d.company.issuerTimelock != address(0)) {
            string memory demo = "demo";
            vm.serializeString(demo, "companyId", "NORTHWIND_LABS");
            vm.serializeAddress(demo, "identityRegistry", d.company.identityRegistry);
            vm.serializeAddress(demo, "trustedVerifiers", d.company.trustedVerifiers);
            vm.serializeAddress(demo, "offeringVault", d.company.offeringVault);
            vm.serializeAddress(demo, "liquidityWindow", d.company.liquidityWindow);
            vm.serializeAddress(demo, "rfqSettlement", d.company.rfqSettlement);
            vm.serializeAddress(demo, "distributionVault", d.company.distributionVault);
            vm.serializeAddress(demo, "governance", d.company.governance);
            vm.serializeAddress(demo, "disclosureRegistry", d.company.disclosureRegistry);
            vm.serializeAddress(demo, "issuerTimelock", d.company.issuerTimelock);
            vm.serializeAddress(demo, "common", d.common);
            string memory demoJson = vm.serializeAddress(demo, "seriesB", d.seriesB);
            json = vm.serializeString(root, "demo", demoJson);
        }

        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Factory:", address(d.factory));
        console2.log("Written to", path);
    }
}
