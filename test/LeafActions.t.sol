// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalTreePlugin} from "../src/CapitalTreePlugin.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {TransferAction} from "../src/actions/TransferAction.sol";
import {TransferBase} from "../src/actions/base/TransferBase.sol";
import {TransferToBeneficiaryAction} from "../src/actions/TransferToBeneficiaryAction.sol";
import {BurnAction} from "../src/actions/BurnAction.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {Asset} from "../src/lib/types.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {FalseReturnToken, FallbackToken} from "./mocks/BadComponents.sol";

contract LeafActionsTest is Fixture {
    BalanceBudget internal budget;

    function setUp() public override {
        super.setUp();
        budget = _deployBalanceBudget(tokenA); // 100 A
    }

    // Transfer

    function testFuzz_TransferSendsTheWholeInput(uint128 _amount, address _recipient) public {
        vm.assume(_recipient != address(0) && _recipient != address(dao));
        _amount = uint128(bound(_amount, 1, type(uint128).max));
        deal(address(tokenA), address(dao), _amount, true);
        CapitalTreePlugin _plugin = _deployPlugin(budget, _one(_deployTransfer(_recipient)));
        _plugin.trigger("", noData);
        assertEq(tokenA.balanceOf(_recipient), _amount);
        assertEq(tokenA.balanceOf(address(dao)), 0);
    }

    function testFuzz_TransferPostconditionMeasuresTheRecipient(uint128 _amount, uint128 _existing) public {
        _amount = uint128(bound(_amount, 1, type(uint128).max));
        tokenA.mint(alice, _existing);
        TransferAction _transfer = _deployTransfer(alice);
        Asset memory _in = Asset(tokenA, _amount);
        Asset memory _out = Asset(tokenA, 0);
        bytes memory _snapshot = _transfer.preconditions(address(0), "", _in, _out);
        assertEq(_snapshot, abi.encode(alice, uint256(_existing)));
        vm.expectRevert(
            abi.encodeWithSelector(
                TransferBase.ReceiptShortfall.selector, address(tokenA), alice, uint256(_existing) + _amount, _existing
            )
        );
        _transfer.postconditions(address(0), _in, _out, _snapshot);
        tokenA.mint(alice, _amount);
        _transfer.postconditions(address(0), _in, _out, _snapshot);
    }

    /// The recipient may end up with more than the transfer, e.g. from another payment in the same block
    function testFuzz_TransferPostconditionAcceptsMoreThanTheInput(uint128 _amount, uint128 _extra) public {
        _amount = uint128(bound(_amount, 1, type(uint128).max));
        _extra = uint128(bound(_extra, 1, type(uint128).max));
        TransferAction _transfer = _deployTransfer(alice);
        Asset memory _in = Asset(tokenA, _amount);
        Asset memory _out = Asset(tokenA, 0);
        bytes memory _snapshot = _transfer.preconditions(address(0), "", _in, _out);
        tokenA.mint(alice, uint256(_amount) + _extra);
        _transfer.postconditions(address(0), _in, _out, _snapshot);
    }

    function testFuzz_RevertWhen_ATransferSilentlyFails(uint128 _amount) public {
        _amount = uint128(bound(_amount, 1, type(uint128).max));
        FalseReturnToken _token = new FalseReturnToken(0);
        _token.mint(address(dao), _amount);
        CapitalTreePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(IERC20(address(_token))), _one(_deployTransfer(alice)));

        // The transfer returns false; the postcondition catches it
        vm.expectRevert(
            abi.encodeWithSelector(TransferBase.ReceiptShortfall.selector, address(_token), alice, _amount, 0)
        );
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_TransferRecipientIsUnset() public {
        TransferAction _transfer = TransferAction(ProxyLib.deployMinimalProxy(address(new TransferAction()), ""));

        vm.expectRevert(TransferAction.NoRecipient.selector);
        _transfer.initialize(dao, _noDeps(), abi.encode(address(0)));
    }

    // Transfer to beneficiary

    function test_RevertWhen_ThereIsNoBeneficiary() public {
        CapitalTreePlugin _plugin = _deployPlugin(budget, _one(toBeneficiary));

        vm.expectRevert(TransferToBeneficiaryAction.NoBeneficiary.selector);
        _plugin.trigger("", noData);
    }

    // Burn

    function testFuzz_BurnLowersTheSupply(uint128 _amount) public {
        _amount = uint128(bound(_amount, 1, type(uint128).max));
        deal(address(tokenA), address(dao), _amount, true);
        CapitalTreePlugin _plugin = _deployPlugin(budget, _one(burn));
        uint256 _supply = tokenA.totalSupply();
        _plugin.trigger("", noData);
        assertEq(tokenA.totalSupply(), _supply - _amount);
        assertEq(tokenA.balanceOf(address(dao)), 0);
    }

    function testFuzz_BurnPostconditionMeasuresTheDao(uint256 _amount) public {
        _amount = bound(_amount, 1, DAO_A);
        Asset memory _in = Asset(tokenA, _amount);
        Asset memory _out = Asset(tokenA, 0);
        bytes memory _snapshot = burn.preconditions(address(0), "", _in, _out);
        assertEq(_snapshot, abi.encode(DAO_A));
        vm.expectRevert(abi.encodeWithSelector(BurnAction.NotBurned.selector, address(tokenA), DAO_A - _amount, DAO_A));
        burn.postconditions(address(0), _in, _out, _snapshot);
        vm.prank(address(dao));
        tokenA.burn(_amount);
        burn.postconditions(address(0), _in, _out, _snapshot);
    }

    function testFuzz_RevertWhen_TheBurnTakesMoreThanItsInput(uint256 _amount, uint256 _extra) public {
        _amount = bound(_amount, 1, DAO_A - 1);
        _extra = bound(_extra, 1, DAO_A - _amount);
        Asset memory _in = Asset(tokenA, _amount);
        Asset memory _out = Asset(tokenA, 0);
        bytes memory _snapshot = burn.preconditions(address(0), "", _in, _out);
        vm.prank(address(dao));
        tokenA.burn(_amount + _extra);

        vm.expectRevert(
            abi.encodeWithSelector(
                BurnAction.Overspent.selector, address(tokenA), DAO_A - _amount, DAO_A - _amount - _extra
            )
        );
        burn.postconditions(address(0), _in, _out, _snapshot);
    }

    function testFuzz_RevertWhen_TheTokenIgnoresBurn(uint128 _amount) public {
        _amount = uint128(bound(_amount, 1, type(uint128).max));
        FallbackToken _token = new FallbackToken();
        _token.mint(address(dao), _amount);
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(IERC20(address(_token))), _one(burn));

        // The burn is a no-op; the postcondition catches it
        vm.expectRevert(abi.encodeWithSelector(BurnAction.NotBurned.selector, address(_token), 0, _amount));
        _plugin.trigger("", noData);
    }

    // Keep

    function testFuzz_KeepLeavesTheInputInTheDao(uint128 _amount) public {
        _amount = uint128(bound(_amount, 1, type(uint128).max));
        deal(address(tokenA), address(dao), _amount, true);
        CapitalTreePlugin _plugin = _deployPlugin(budget, _one(keep));
        _plugin.trigger("", noData);
        assertEq(tokenA.balanceOf(address(dao)), _amount);
    }

    // Branches of transfers

    /// capital-router checks each transfer against a snapshot taken before any of them, so a
    /// recipient listed twice can miss a silent failure. Here every leaf checks its own receipt.
    function test_RevertWhen_ARepeatedRecipientMissesATransfer() public {
        FalseReturnToken _token = new FalseReturnToken(1); // the second transfer silently fails
        _token.mint(address(dao), 100 ether);
        CapitalTreePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(IERC20(address(_token))),
            _fork(NO_ACTION, 500_000, _deployTransfer(alice), 500_000, _deployTransfer(alice))
        );

        // The second leaf's transfer returns false; its postcondition catches it
        vm.expectRevert(
            abi.encodeWithSelector(TransferBase.ReceiptShortfall.selector, address(_token), alice, 100 ether, 50 ether)
        );
        _plugin.trigger("", noData);
    }

    // Implementations

    function test_RevertWhen_InitializingAnImplementation() public {
        BurnAction _burn = new BurnAction();
        KeepAction _keep = new KeepAction();
        TransferToBeneficiaryAction _toBeneficiary = new TransferToBeneficiaryAction();

        vm.expectRevert("Initializable: contract is already initialized");
        _burn.initialize(dao, _noDeps(), "");
        vm.expectRevert("Initializable: contract is already initialized");
        _keep.initialize(dao, _noDeps(), "");
        vm.expectRevert("Initializable: contract is already initialized");
        _toBeneficiary.initialize(dao, _noDeps(), "");
    }
}

contract BalanceBudgetTest is Fixture {
    function testFuzz_AvailableIsTheDaoBalance(uint256 _amount, address _caller, bytes memory _data) public {
        deal(address(tokenA), address(dao), _amount, true);
        BalanceBudget _budget = _deployBalanceBudget(tokenA);
        assertEq(_budget.available(_caller, _data), _amount);
        assertEq(address(_budget.token()), address(tokenA));
    }

    function testFuzz_CommitsNothing(address _caller, bytes memory _data) public {
        assertEq(_deployBalanceBudget(tokenA).commitActions(_caller, _data).length, 0);
    }

    function test_RevertWhen_TokenHasNoCode() public {
        BalanceBudget _budget = BalanceBudget(ProxyLib.deployMinimalProxy(address(new BalanceBudget()), ""));

        vm.expectRevert(BalanceBudget.InvalidToken.selector);
        _budget.initialize(dao, _noDeps(), abi.encode(IERC20(address(0xBEEF))));
    }

    function test_RevertWhen_TokenIsUnset() public {
        BalanceBudget _budget = BalanceBudget(ProxyLib.deployMinimalProxy(address(new BalanceBudget()), ""));

        vm.expectRevert(BalanceBudget.InvalidToken.selector);
        _budget.initialize(dao, _noDeps(), abi.encode(IERC20(address(0))));
    }
}
