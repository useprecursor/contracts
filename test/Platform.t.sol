// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {PrecursorFactory} from "../src/PrecursorFactory.sol";
import {IPrecursorFactory} from "../src/interfaces/IPrecursorFactory.sol";
import {PrecursorShareToken} from "../src/PrecursorShareToken.sol";
import {IssuerTimelock} from "../src/IssuerTimelock.sol";
import {DisclosureRegistry} from "../src/DisclosureRegistry.sol";
import {ValuationOracle} from "../src/ValuationOracle.sol";
import {PoolGate} from "../src/PoolGate.sol";
import {RuleEngine} from "../src/RuleEngine.sol";
import {ReasonCodes} from "../src/libraries/ReasonCodes.sol";
import {Topics} from "../src/libraries/Topics.sol";

contract PlatformTest is Base {
    // Factory

    function test_FactoryRecordsEverything() public {
        PrecursorShareToken token = _plainClass("COMMON");
        IPrecursorFactory.ShareClassInfo memory info = factory.shareClassOf(address(token));
        assertEq(info.companyId, COMPANY);
        assertEq(info.ruleEngine, address(token.ruleEngine()));
        assertEq(factory.shareTokens(COMPANY).length, 1);
        assertEq(factory.shareTokenOf(COMPANY, "COMMON"), address(token));
        assertEq(factory.companyContracts(COMPANY).issuerTimelock, address(timelock));
    }

    function test_FactoryGuards() public {
        vm.expectRevert();
        factory.deployShareClass(_params("X", new PrecursorFactory.ModuleInit[](0), false));

        _plainClass("COMMON");
        vm.prank(precursor);
        vm.expectRevert(PrecursorFactory.ShareClassExists.selector);
        factory.deployShareClass(_params("COMMON", new PrecursorFactory.ModuleInit[](0), false));

        vm.prank(precursor);
        vm.expectRevert(abi.encodeWithSelector(PrecursorFactory.UnknownModule.selector, bytes32("NOPE")));
        factory.deployShareClass(_params("Y", _modules1("NOPE", ""), false));
    }

    function test_FactoryEmitsShareClassDeployed() public {
        vm.recordLogs();
        PrecursorShareToken token = _plainClass("COMMON");
        bool seen;
        bytes32 sig = keccak256("ShareClassDeployed(bytes32,bytes32,address,address,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == sig) {
                (address t,,) = abi.decode(logs[i].data, (address, address, address));
                seen = t == address(token);
            }
        }
        assertTrue(seen);
    }

    // Timelock

    function test_TimelockDelaysBySelector() public view {
        assertEq(timelock.delayFor(bytes4(keccak256("upgradeToAndCall(address,bytes)"))), 7 days);
        assertEq(timelock.delayFor(RuleEngine.addModule.selector), 24 hours);
        assertEq(timelock.delayFor(bytes4(keccak256("grantRole(bytes32,address)"))), 48 hours);
    }

    function test_TimelockThresholdAndExecution() public {
        bytes memory data = abi.encodeCall(IssuerTimelock.setThreshold, (3));
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(timelock), 0, data, "t");
        vm.expectRevert(IssuerTimelock.NotQueued.selector);
        timelock.execute(id);

        vm.prank(signer2);
        timelock.approve(id);
        vm.expectRevert(IssuerTimelock.TooEarly.selector);
        timelock.execute(id);
        vm.warp(T0 + 48 hours);
        timelock.execute(id);
        assertEq(timelock.threshold(), 3);
    }

    function test_RemovedSignerApprovalStopsCounting() public {
        bytes memory data = abi.encodeCall(IssuerTimelock.setDelay, (bytes4(0x12345678), 72 hours));
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(timelock), 0, data, "d");

        _timelocked(address(timelock), abi.encodeCall(IssuerTimelock.removeSigner, (signer1)));
        vm.prank(signer2);
        timelock.approve(id); // queued: two approvals recorded, but signer1 no longer counts
        vm.warp(block.timestamp + 72 hours);
        vm.expectRevert(IssuerTimelock.NotQueued.selector);
        timelock.execute(id);
    }

    function test_TimelockCannotGoBelowFloor() public {
        bytes memory data = abi.encodeCall(IssuerTimelock.setDelay, (RuleEngine.addModule.selector, 1 hours));
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(timelock), 0, data, "floor");
        vm.prank(signer2);
        timelock.approve(id);
        vm.warp(T0 + 48 hours);
        vm.expectRevert();
        timelock.execute(id);

        vm.expectRevert(IssuerTimelock.OnlySelf.selector);
        timelock.addSigner(alice);
    }

    // Disclosures and valuations

    function test_DisclosureRegistry() public {
        bytes32 hash = sha256("board resolution v1");
        vm.prank(issuerAdmin);
        uint256 id = disclosures.anchor("BOARD_RESOLUTION", hash, "ipfs://doc");
        assertEq(id, 1);
        assertEq(disclosures.document(id).hash, hash);
        assertEq(disclosures.documentIdByHash(hash), 1);

        vm.prank(issuerAdmin);
        vm.expectRevert(abi.encodeWithSelector(DisclosureRegistry.AlreadyAnchored.selector, 1));
        disclosures.anchor("COMPANY_UPDATE", hash, "ipfs://copy");

        vm.prank(issuerAdmin);
        vm.expectRevert(DisclosureRegistry.InvalidKind.selector);
        disclosures.anchor("MEME", hash, "");
        vm.prank(alice);
        vm.expectRevert();
        disclosures.anchor("COMPANY_UPDATE", hash, "");
    }

    function test_ValuationOracleAggregatorView() public {
        PrecursorShareToken token = _plainClass("COMMON");
        ValuationOracle oracle = ValuationOracle(factory.shareClassOf(address(token)).valuationOracle);
        vm.expectRevert(ValuationOracle.NoData.selector);
        oracle.latestRoundData();

        vm.prank(issuerAdmin);
        oracle.publish(12.5e8, 1, uint64(T0 - 1 days), keccak256("409a"));
        (uint80 round, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(round, 1);
        assertEq(answer, 12.5e8);
        assertEq(updatedAt, T0 - 1 days);
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.description(), "NWD / USD reference valuation");

        vm.prank(issuerAdmin);
        vm.expectRevert(ValuationOracle.InvalidDate.selector);
        oracle.publish(11e8, 1, uint64(T0 - 2 days), 0);

        vm.prank(issuerAdmin);
        token.pause("split");
        vm.prank(issuerAdmin);
        vm.expectRevert(ValuationOracle.TokenPaused.selector);
        oracle.publish(1e8, 1, uint64(T0), 0);
    }

    // Pools

    function test_PoolGateRequiresVenueClaimAndBlocksRofrClasses() public {
        vm.prank(precursor);
        PrecursorShareToken token = PrecursorShareToken(
            factory.deployShareClass(_params("POOLED", new PrecursorFactory.ModuleInit[](0), true))
        );
        PoolGate gate = PoolGate(factory.shareClassOf(address(token)).poolGate);
        address pool = address(new PoolStub());

        vm.prank(address(timelock));
        vm.expectRevert(PoolGate.NotVenue.selector);
        gate.registerPool(pool);

        vm.prank(operator);
        registry.registerIdentity(pool, pool);
        _addClaim(pool, Topics.VENUE, abi.encode(address(token)));
        assertTrue(token.isAgent(pool));
        vm.prank(address(timelock));
        gate.registerPool(pool);

        _verify(alice);
        _mint(token, pool, _shares(10)); // pools are agents, so they can hold inventory
        assertEq(gate.checkSwap(pool, alice, 1), ReasonCodes.OK);
        assertEq(gate.checkSwap(pool, bob, 1), ReasonCodes.RECIPIENT_NOT_VERIFIED);
        vm.prank(pool);
        vm.expectRevert();
        gate.beforeAddLiquidity(bob);

        vm.prank(address(timelock));
        gate.removePool(pool);
        assertEq(gate.checkSwap(pool, alice, 1), ReasonCodes.NOT_ELIGIBLE);
        vm.prank(address(timelock));
        vm.expectRevert(PoolGate.UnknownPool.selector);
        gate.removePool(pool);

        address[] memory venues = new address[](0);
        vm.prank(precursor);
        PrecursorShareToken rofrToken = PrecursorShareToken(
            factory.deployShareClass(_params("ROFR", _modules1("ROFR", abi.encode(treasury, uint32(1), venues)), true))
        );
        PoolGate rofrGate = PoolGate(factory.shareClassOf(address(rofrToken)).poolGate);
        vm.prank(address(timelock));
        vm.expectRevert(PoolGate.ROFRIncompatible.selector);
        rofrGate.registerPool(pool);
    }

    function _params(bytes32 cls, PrecursorFactory.ModuleInit[] memory modules, bool pools)
        internal
        pure
        returns (PrecursorFactory.ShareClassParams memory)
    {
        return PrecursorFactory.ShareClassParams({
            companyId: COMPANY,
            shareClass: cls,
            name: "Northwind",
            symbol: "NWD",
            documentsRoot: bytes32(0),
            modules: modules,
            enablePools: pools
        });
    }
}

contract PoolStub {}

import {Vm} from "forge-std/Vm.sol";
