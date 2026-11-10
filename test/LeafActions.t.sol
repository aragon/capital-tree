// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
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

    function test_TransferSendsTheWholeInput() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_deployTransfer(alice)));

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), DAO_A);
        assertEq(tokenA.balanceOf(address(dao)), 0);
    }

    function test_TransferPostconditionMeasuresTheRecipient() public {
        TransferAction _transfer = _deployTransfer(alice);
        Asset memory _in = Asset(tokenA, 7 ether);
        Asset memory _out = Asset(tokenA, 0);
        uint256 _before = tokenA.balanceOf(alice);

        bytes memory _snapshot = _transfer.preconditions(address(0), "", _in, _out);
        assertEq(_snapshot, abi.encode(alice, _before));

        vm.expectRevert(
            abi.encodeWithSelector(
                TransferBase.ReceiptShortfall.selector, address(tokenA), alice, _before + 7 ether, _before
            )
        );
        _transfer.postconditions(address(0), _in, _out, _snapshot);

        tokenA.mint(alice, 7 ether);
        _transfer.postconditions(address(0), _in, _out, _snapshot);
    }

    function test_RevertWhen_ATransferSilentlyFails() public {
        FalseReturnToken _token = new FalseReturnToken(0);
        _token.mint(address(dao), 100 ether);
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(IERC20(address(_token))), _one(_deployTransfer(alice)));

        // The transfer returns false; the postcondition catches it
        vm.expectRevert(
            abi.encodeWithSelector(TransferBase.ReceiptShortfall.selector, address(_token), alice, 100 ether, 0)
        );
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_TransferRecipientIsUnset() public {
        TransferAction _transfer = TransferAction(ProxyLib.deployMinimalProxy(address(new TransferAction()), ""));

        vm.expectRevert(TransferAction.NoRecipient.selector);
        _transfer.initialize(dao, address(0));
    }

    // Transfer to beneficiary

    function test_RevertWhen_ThereIsNoBeneficiary() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(toBeneficiary));

        vm.expectRevert(TransferToBeneficiaryAction.NoBeneficiary.selector);
        _plugin.trigger("", noData);
    }

    // Burn

    function test_BurnLowersTheSupply() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(burn));
        uint256 _supply = tokenA.totalSupply();

        _plugin.trigger("", noData);

        assertEq(tokenA.totalSupply(), _supply - DAO_A);
    }

    function test_BurnPostconditionMeasuresTheDao() public {
        Asset memory _in = Asset(tokenA, 7 ether);
        Asset memory _out = Asset(tokenA, 0);

        bytes memory _snapshot = burn.preconditions(address(0), "", _in, _out);
        assertEq(_snapshot, abi.encode(DAO_A));

        vm.expectRevert(abi.encodeWithSelector(BurnAction.NotBurned.selector, address(tokenA), DAO_A - 7 ether, DAO_A));
        burn.postconditions(address(0), _in, _out, _snapshot);

        vm.prank(address(dao));
        tokenA.burn(7 ether);
        burn.postconditions(address(0), _in, _out, _snapshot);
    }

    function test_RevertWhen_TheTokenIgnoresBurn() public {
        FallbackToken _token = new FallbackToken();
        _token.mint(address(dao), 100 ether);
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(IERC20(address(_token))), _one(burn));

        // The burn is a no-op; the postcondition catches it
        vm.expectRevert(abi.encodeWithSelector(BurnAction.NotBurned.selector, address(_token), 0, 100 ether));
        _plugin.trigger("", noData);
    }

    // Keep

    function test_KeepLeavesTheInputInTheDao() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(keep));

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(address(dao)), DAO_A);
    }

    // Branches of transfers

    /// capital-router checks each transfer against a snapshot taken before any of them, so a
    /// recipient listed twice can miss a silent failure. Here every leaf checks its own receipt.
    function test_RevertWhen_ARepeatedRecipientMissesATransfer() public {
        FalseReturnToken _token = new FalseReturnToken(1); // the second transfer silently fails
        _token.mint(address(dao), 100 ether);
        CapitalPipelinePlugin _plugin = _deployPlugin(
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
        _burn.initialize(dao);
        vm.expectRevert("Initializable: contract is already initialized");
        _keep.initialize(dao);
        vm.expectRevert("Initializable: contract is already initialized");
        _toBeneficiary.initialize(dao);
    }
}

contract BalanceBudgetTest is Fixture {
    function test_AvailableIsTheDaoBalance() public {
        BalanceBudget _budget = _deployBalanceBudget(tokenA);

        assertEq(_available(_budget), DAO_A);
        assertEq(address(_budget.token()), address(tokenA));
    }

    function test_CommitsNothing() public {
        assertEq(_deployBalanceBudget(tokenA).commitActions(alice, "").length, 0);
    }

    function test_RevertWhen_TokenHasNoCode() public {
        BalanceBudget _budget = BalanceBudget(ProxyLib.deployMinimalProxy(address(new BalanceBudget()), ""));

        vm.expectRevert(BalanceBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0xBEEF)));
    }

    function test_RevertWhen_TokenIsUnset() public {
        BalanceBudget _budget = BalanceBudget(ProxyLib.deployMinimalProxy(address(new BalanceBudget()), ""));

        vm.expectRevert(BalanceBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0)));
    }
}
