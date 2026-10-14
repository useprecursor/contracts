// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {PrecursorFactory} from "../src/PrecursorFactory.sol";
import {PrecursorShareToken} from "../src/PrecursorShareToken.sol";
import {RuleEngine} from "../src/RuleEngine.sol";
import {HoldingPeriodModule} from "../src/modules/HoldingPeriodModule.sol";
import {HolderCapModule} from "../src/modules/HolderCapModule.sol";
import {TransferWindowModule} from "../src/modules/TransferWindowModule.sol";
import {ROFRModule} from "../src/modules/ROFRModule.sol";
import {EmployeeVestingModule} from "../src/modules/EmployeeVestingModule.sol";
import {ReasonCodes} from "../src/libraries/ReasonCodes.sol";
import {Topics} from "../src/libraries/Topics.sol";

contract ModulesTest is Base {
    function setUp() public override {
        super.setUp();
        _verify(alice, US, 2);
        _verify(bob, GB, 1);
        _verify(carol, KP, 3);
        _verify(dave, SG, 0);
    }

    function _module(PrecursorShareToken token, uint256 i) internal view returns (address) {
        return RuleEngine(address(token.ruleEngine())).modules()[i];
    }

    function _code(PrecursorShareToken token, address from, address to, uint256 amount)
        internal
        view
        returns (bytes32 code)
    {
        (, code) = token.canTransfer(from, to, amount);
    }

    function test_RegionAllowList() public {
        bytes2[] memory regions = new bytes2[](2);
        regions[0] = US;
        regions[1] = GB;
        PrecursorShareToken token = _deployClass("C", _modules1("REGION", abi.encode(uint8(0), regions)));
        _mint(token, alice, 100);
        assertEq(_code(token, alice, bob, 1), ReasonCodes.OK);
        assertEq(_code(token, alice, dave, 1), ReasonCodes.REGION_BLOCKED);
    }

    function test_RegionBlockList() public {
        bytes2[] memory regions = new bytes2[](1);
        regions[0] = KP;
        PrecursorShareToken token = _deployClass("C", _modules1("REGION", abi.encode(uint8(1), regions)));
        _mint(token, alice, 100);
        assertEq(_code(token, alice, dave, 1), ReasonCodes.OK);
        assertEq(_code(token, alice, carol, 1), ReasonCodes.REGION_BLOCKED);
    }

    function test_EligibilityTierAndEmployeeExemption() public {
        PrecursorShareToken token = _deployClass("C", _modules1("ELIGIBILITY", abi.encode(uint8(1), true)));
        _mint(token, alice, 100);
        assertEq(_code(token, alice, bob, 1), ReasonCodes.OK);
        assertEq(_code(token, alice, dave, 1), ReasonCodes.NOT_ELIGIBLE);
        _addClaim(dave, Topics.EMPLOYEE_OF, abi.encode(COMPANY));
        assertEq(_code(token, alice, dave, 1), ReasonCodes.OK);
    }

    function test_HoldingPeriodFifoLots() public {
        bytes memory config =
            abi.encode(uint32(30 days), new bytes32[](0), new uint32[](0), new address[](0), new bytes32[](0));
        PrecursorShareToken token = _deployClass("C", _modules1("HOLDING_PERIOD", config));
        HoldingPeriodModule hp = HoldingPeriodModule(_module(token, 0));

        _mint(token, alice, 1_000);
        vm.warp(T0 + 10 days);
        _mint(token, alice, 2_000);

        assertEq(_code(token, alice, bob, 1), ReasonCodes.HOLDING_PERIOD_ACTIVE);
        vm.warp(T0 + 30 days); // first lot unlocked, second not
        assertEq(token.unlockedBalanceOf(alice), 1_000);
        assertEq(_code(token, alice, bob, 1_001), ReasonCodes.HOLDING_PERIOD_ACTIVE);

        vm.prank(alice);
        token.transfer(bob, 1_000);
        assertEq(hp.lotsOf(alice).length, 1);
        assertEq(hp.lotsOf(alice)[0].amount, 2_000);
        // Bob's tokens are a new lot with a fresh lockup.
        assertEq(_code(token, bob, alice, 1), ReasonCodes.HOLDING_PERIOD_ACTIVE);
    }

    function test_HoldingPeriodSourceOverride() public {
        bytes32[] memory sources = new bytes32[](1);
        sources[0] = "OFFERING";
        uint32[] memory periods = new uint32[](1);
        periods[0] = 90 days;
        address[] memory ops = new address[](1);
        ops[0] = address(offerings);
        bytes memory config = abi.encode(uint32(0), sources, periods, ops, sources);
        PrecursorShareToken token = _deployClass("C", _modules1("HOLDING_PERIOD", config));
        _mint(token, alice, 500); // ISSUANCE, no lockup
        assertEq(_code(token, alice, bob, 500), ReasonCodes.OK);
        HoldingPeriodModule hp = HoldingPeriodModule(_module(token, 0));
        assertEq(hp.periodFor("OFFERING"), 90 days);
        assertEq(hp.operatorSource(address(offerings)), bytes32("OFFERING"));
    }

    function test_HolderCap() public {
        PrecursorShareToken token = _deployClass("C", _modules1("HOLDER_CAP", abi.encode(uint32(2))));
        _mint(token, alice, 100);
        _mint(token, bob, 100);
        assertEq(HolderCapModule(_module(token, 0)).holderCount(), 2);
        assertEq(_code(token, alice, dave, 10), ReasonCodes.HOLDER_CAP_REACHED);
        assertEq(_code(token, alice, bob, 10), ReasonCodes.OK);
        // Closing out the whole position keeps the count the same, so it is allowed.
        assertEq(_code(token, alice, dave, 100), ReasonCodes.OK);
        vm.prank(alice);
        token.transfer(dave, 100);
        assertEq(HolderCapModule(_module(token, 0)).holderCount(), 2);
    }

    function test_TransferWindow() public {
        TransferWindowModule.Window[] memory w = new TransferWindowModule.Window[](1);
        w[0] = TransferWindowModule.Window({opensAt: uint40(T0 + 1 days), closesAt: uint40(T0 + 2 days)});
        PrecursorShareToken token =
            _deployClass("C", _modules1("TRANSFER_WINDOW", abi.encode(w, true, address(windows))));
        _mint(token, alice, 100); // mints always pass
        assertEq(_code(token, alice, bob, 1), ReasonCodes.WINDOW_CLOSED);
        assertEq(_code(token, alice, address(windows), 1), ReasonCodes.OK);
        vm.warp(T0 + 1 days);
        assertEq(_code(token, alice, bob, 1), ReasonCodes.OK);
        vm.warp(T0 + 2 days);
        assertEq(_code(token, alice, bob, 1), ReasonCodes.WINDOW_CLOSED);
    }

    function test_ROFRNoticeWaiveAndExercise() public {
        address[] memory venues = new address[](1);
        venues[0] = address(windows);
        PrecursorShareToken token = _deployClass("C", _modules1("ROFR", abi.encode(treasury, uint32(14 days), venues)));
        ROFRModule rofr = ROFRModule(_module(token, 0));
        _mint(token, alice, 100);

        assertEq(_code(token, alice, bob, 10), ReasonCodes.ROFR_PENDING);
        vm.prank(alice);
        rofr.propose(bob, 10);
        assertEq(_code(token, alice, bob, 10), ReasonCodes.ROFR_PENDING);
        vm.warp(T0 + 14 days);
        assertEq(_code(token, alice, bob, 11), ReasonCodes.ROFR_PENDING);
        vm.prank(alice);
        token.transfer(bob, 10);
        assertEq(_code(token, alice, bob, 1), ReasonCodes.ROFR_PENDING); // proposal consumed

        vm.prank(alice);
        rofr.propose(dave, 5);
        vm.prank(treasury);
        rofr.waive(alice, dave);
        assertEq(_code(token, alice, dave, 5), ReasonCodes.OK);

        vm.prank(alice);
        rofr.propose(bob, 20);
        vm.prank(treasury);
        rofr.exercise(alice, bob);
        vm.warp(T0 + 44 days);
        assertEq(_code(token, alice, bob, 20), ReasonCodes.ROFR_PENDING);
        assertEq(_code(token, alice, address(windows), 20), ReasonCodes.OK);
    }

    function test_MaxOwnership() public {
        address[] memory exempt = new address[](1);
        exempt[0] = alice;
        PrecursorShareToken token =
            _deployClass("C", _modules1("MAX_OWNERSHIP", abi.encode(uint16(1_000), false, exempt)));
        _mint(token, alice, 1_000); // cap table import ignores the cap (applyToMints = false)
        assertEq(_code(token, alice, bob, 100), ReasonCodes.OK);
        assertEq(_code(token, alice, bob, 101), ReasonCodes.MAX_OWNERSHIP_EXCEEDED);
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(_code(token, alice, bob, 1), ReasonCodes.MAX_OWNERSHIP_EXCEEDED);
    }

    function test_EmployeeVesting() public {
        PrecursorShareToken token =
            _deployClass("C", _modules1("EMPLOYEE_VESTING", abi.encode(uint8(0), abi.encode(true))));
        EmployeeVestingModule vest = EmployeeVestingModule(_module(token, 0));
        _mint(token, alice, 4_000);

        EmployeeVestingModule.Grant[] memory grants = new EmployeeVestingModule.Grant[](1);
        grants[0] = EmployeeVestingModule.Grant({
            start: uint64(block.timestamp), cliff: 365 days, duration: 4 * 365 days, total: 4_000, accelerated: false
        });
        vm.prank(alice);
        vm.expectRevert(EmployeeVestingModule.NotRegistrar.selector);
        vest.addGrants(alice, grants);
        vm.prank(registrar);
        vest.addGrants(alice, grants);

        assertEq(_code(token, alice, bob, 1), ReasonCodes.UNVESTED);
        assertEq(token.unlockedBalanceOf(alice), 0);
        vm.warp(T0 + 365 days);
        assertEq(token.unlockedBalanceOf(alice), 1_000);
        assertEq(_code(token, alice, bob, 1_000), ReasonCodes.OK);
        assertEq(_code(token, alice, bob, 1_001), ReasonCodes.UNVESTED);

        _timelocked(
            address(token.ruleEngine()),
            abi.encodeCall(
                RuleEngine.configureModule, (address(vest), abi.encode(uint8(1), abi.encode(alice, uint256(0))))
            )
        );
        assertEq(_code(token, alice, bob, 4_000), ReasonCodes.OK);
    }

    function test_ModuleChangesNeedTimelock() public {
        PrecursorShareToken token = _plainClass("C");
        RuleEngine engine = RuleEngine(address(token.ruleEngine()));
        vm.prank(issuerAdmin);
        vm.expectRevert();
        engine.removeModule(address(1));

        _mint(token, alice, 100);
        assertEq(_code(token, alice, dave, 1), ReasonCodes.OK);
        // A module must be bound to this engine before it can be added.
        HolderCapModule rogue = new HolderCapModule();
        bytes memory data = abi.encodeCall(RuleEngine.addModule, (address(rogue), abi.encode(uint32(1))));
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(engine), 0, data, "rogue");
        vm.prank(signer2);
        timelock.approve(id);
        assertEq(timelock.action(id).eta, T0 + 24 hours);
        vm.warp(T0 + 24 hours);
        vm.expectRevert();
        timelock.execute(id);
    }

    function test_FirstFailingModuleWins() public {
        bytes2[] memory regions = new bytes2[](1);
        regions[0] = US;
        PrecursorFactory.ModuleInit[] memory m = new PrecursorFactory.ModuleInit[](2);
        m[0] = PrecursorFactory.ModuleInit("REGION", abi.encode(uint8(0), regions));
        m[1] = PrecursorFactory.ModuleInit("ELIGIBILITY", abi.encode(uint8(5), false));
        PrecursorShareToken token = _deployClass("C", m);
        assertEq(_code(token, address(0), dave, 1), ReasonCodes.REGION_BLOCKED);
        assertEq(_code(token, address(0), alice, 1), ReasonCodes.NOT_ELIGIBLE);
    }
}
