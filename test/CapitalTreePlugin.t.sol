// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {IExecutor} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalTreePlugin} from "../src/CapitalTreePlugin.sol";
import {StreamBudget} from "../src/budgets/StreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimBudget} from "../src/budgets/MerkleClaimBudget.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {WeightSplitter} from "../src/splitters/WeightSplitter.sol";
import {IBudget} from "../src/interfaces/IBudget.sol";
import {INodeAction} from "../src/interfaces/INodeAction.sol";
import {ISplitter} from "../src/interfaces/ISplitter.sol";
import {Asset, Node} from "../src/lib/types.sol";
import {CONFIGURE_PERMISSION_ID, PAUSE_PERMISSION_ID, RATIO_BASE} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockFiller} from "./mocks/MockFiller.sol";
import {MockExchange, MockSwapAction} from "./mocks/MockSwap.sol";
import {BadAction, WritingCheckAction} from "./mocks/BadComponents.sol";
import {CapSplitter, FixedSplitter} from "./mocks/MockSplitter.sol";
import {IncomeAction, IncomeSource} from "./mocks/MockIncome.sol";

contract CapitalTreePluginTest is Fixture {
    IERC20 internal constant NO_TOKEN = IERC20(address(0));

    StreamBudget internal budget;
    OpenFillAction internal action;
    CapitalTreePlugin internal plugin;
    MockFiller internal filler;

    /// @dev Swap 10 A for 1,000 B, then pay 95% to the burn address and 5% to the fee address
    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
        action = _deployAction(budget);
        plugin = _deployPlugin(budget, _splitToBurnAndFee(action));

        filler = new MockFiller(plugin);
        tokenB.mint(address(filler), 1_000_000 ether);

        vm.warp(block.timestamp + EPOCH); // 10 A on offer
    }

    // =========================================================================================
    // Configuration
    // =========================================================================================

    function test_StoresTheFlow() public view {
        Node[] memory _stored = plugin.nodes();

        assertEq(address(plugin.budget()), address(budget));
        assertEq(_stored.length, 3);
        assertEq(address(_stored[0].action), address(action));
        assertEq(_stored[0].children[1], 2);
        assertEq(WeightSplitter(address(_stored[0].splitter)).weights()[0], 950_000);
        assertEq(_stored[2].children.length, 0);
    }

    function test_DaoReplacesTheFlow() public {
        vm.prank(address(dao));
        plugin.setFlow(budget, _one(keep));

        assertEq(plugin.nodes().length, 1);
        assertEq(address(plugin.nodes()[0].action), address(keep));
    }

    function test_ManagerPausesAndUnpauses() public {
        vm.prank(manager);
        plugin.pause();
        assertTrue(plugin.paused());

        vm.prank(manager);
        plugin.unpause();
        assertFalse(plugin.paused());
    }

    function test_RevertWhen_PauseUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(plugin), address(this), PAUSE_PERMISSION_ID
            )
        );
        plugin.pause();
    }

    function test_RevertWhen_ManagerSetsTheFlow() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(plugin), manager, CONFIGURE_PERMISSION_ID
            )
        );
        vm.prank(manager);
        plugin.setFlow(budget, _one(keep));
    }

    function test_RevertWhen_NoBudget() public {
        _expectInitRevert(IBudget(address(0)), _one(keep), abi.encodeWithSelector(CapitalTreePlugin.NoBudget.selector));
    }

    function test_RevertWhen_NoNodes() public {
        _expectInitRevert(budget, new Node[](0), abi.encodeWithSelector(CapitalTreePlugin.InvalidNodeCount.selector, 0));
    }

    /// Vary branch width across and beyond the old 16-node limit.
    function testFuzz_RunsWideFlow(uint32 _leafCount) public {
        _leafCount = uint32(bound(_leafCount, 2, 64));
        INodeAction _toAlice = _deployTransfer(alice);
        Node[] memory _tree = new Node[](_leafCount + 1);
        _tree[0].children = new uint32[](_leafCount);
        uint32[] memory _weights = new uint32[](_leafCount);
        for (uint32 i; i < _leafCount; ++i) {
            _tree[0].children[i] = i + 1;
            _tree[i + 1] = _leaf(_toAlice);
            _weights[i] = uint32(RATIO_BASE / _leafCount);
        }
        _weights[0] += uint32(RATIO_BASE % _leafCount);
        _tree[0].splitter = _deployWeightSplitter(_weights);
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _plugin.trigger("", noData);

        assertEq(_plugin.nodes().length, _leafCount + 1);
        assertEq(tokenA.balanceOf(alice), DAO_A);
    }

    function test_RevertWhen_ALeafHasNoAction() public {
        _expectInitRevert(budget, _one(NO_ACTION), abi.encodeWithSelector(CapitalTreePlugin.MissingAction.selector, 0));
    }

    function test_RevertWhen_AChildDoesNotComeAfterItsParent() public {
        Node[] memory _tree = new Node[](1);
        _tree[0] = _then(keep, 0);

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalTreePlugin.InvalidChild.selector, 0, 0));
    }

    function test_RevertWhen_ANodeHasTwoParents() public {
        Node[] memory _tree = new Node[](3);
        (_tree[0], _tree[1], _tree[2]) = (_branch(NO_ACTION, 1, 500_000, 2, 500_000), _then(keep, 2), _leaf(keep));

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalTreePlugin.InvalidChild.selector, 1, 2));
    }

    function test_RevertWhen_AChildIsOutOfRange() public {
        Node[] memory _tree = new Node[](2);
        (_tree[0], _tree[1]) = (_then(keep, 2), _leaf(keep));

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalTreePlugin.InvalidChild.selector, 0, 2));
    }

    function test_RevertWhen_ANodeIsUnreachable() public {
        Node[] memory _tree = new Node[](2);
        (_tree[0], _tree[1]) = (_leaf(keep), _leaf(keep));

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalTreePlugin.UnreachableNode.selector, 1));
    }

    function test_RevertWhen_ABranchHasNoSplitter() public {
        Node[] memory _tree = _fork(NO_ACTION, 500_000, keep, 500_000, keep);
        _tree[0].splitter = ISplitter(address(0));

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalTreePlugin.InvalidSplitter.selector, 0));
    }

    function test_RevertWhen_ABoundActionBelowTheRootUsesAnotherBudget() public {
        Node[] memory _tree = new Node[](4);
        _tree[0] = _branch(NO_ACTION, 1, 500_000, 2, 500_000);
        _tree[1] = _leaf(keep);
        _tree[2] = _then(action, 3);
        _tree[3] = _leaf(keep);

        _expectInitRevert(
            _deployBudget(RATE, 0), _tree, abi.encodeWithSelector(CapitalTreePlugin.BudgetMismatch.selector, 2)
        );
    }

    function test_RevertWhen_ANodeIsAnImplementation() public {
        KeepAction _implementation = new KeepAction();

        _expectInitRevert(
            budget,
            _one(_implementation),
            abi.encodeWithSelector(CapitalTreePlugin.ForeignComponent.selector, address(_implementation))
        );
    }

    function test_RevertWhen_ANodeBelongsToAnotherDao() public {
        KeepAction _foreign = _deployKeep(IDAO(makeAddr("otherDao")));

        _expectInitRevert(
            budget,
            _one(_foreign),
            abi.encodeWithSelector(CapitalTreePlugin.ForeignComponent.selector, address(_foreign))
        );
    }

    function test_RevertWhen_TheBudgetBelongsToAnotherDao() public {
        BalanceBudget _foreign = BalanceBudget(
            ProxyLib.deployMinimalProxy(
                address(new BalanceBudget()),
                abi.encodeCall(BalanceBudget.initialize, (IDAO(makeAddr("otherDao")), _noDeps(), abi.encode(tokenA)))
            )
        );

        _expectInitRevert(
            _foreign, _one(keep), abi.encodeWithSelector(CapitalTreePlugin.ForeignComponent.selector, address(_foreign))
        );
    }

    function test_RevertWhen_TheRootIsBoundToAnotherBudget() public {
        _expectInitRevert(
            _deployBudget(RATE, 0),
            _chain(action, keep),
            abi.encodeWithSelector(CapitalTreePlugin.BudgetMismatch.selector, 0)
        );
    }

    /// The bound budget must equal the flow's, whichever address is lower
    function test_RevertWhen_TheRootIsBoundToAnotherBudgetInEitherOrder() public {
        StreamBudget _other = _deployBudget(RATE, 0);
        bytes memory _error = abi.encodeWithSelector(CapitalTreePlugin.BudgetMismatch.selector, 0);

        _expectInitRevert(_other, _chain(action, keep), _error);
        _expectInitRevert(budget, _chain(_deployAction(_other), keep), _error);
    }

    // =========================================================================================
    // Running flows
    // =========================================================================================

    function test_FillSwapsAndSplitsTheProceeds() public {
        filler.fill("");

        assertEq(tokenA.balanceOf(address(dao)), DAO_A - RATE, "DAO hands over the offer");
        assertEq(tokenA.balanceOf(address(filler)), RATE, "filler receives the offer");
        assertEq(tokenA.allowance(address(dao), address(filler)), 0, "no approval survives");
        assertEq(tokenB.balanceOf(BURN), 950 ether, "95% to the burn address");
        assertEq(tokenB.balanceOf(fee), 50 ether, "5% fee");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B, "pre-existing B untouched");
        assertEq(_available(budget), 0, "auction restarts");
    }

    /// The example tree: swap, burn 95%, send 5% to a fee address
    function test_BuybackBurnsAndPaysAFee() public {
        CapitalTreePlugin _plugin = _deployPlugin(budget, _fork(action, 950_000, burn, 50_000, _deployTransfer(fee)));
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), DEMAND);
        uint256 _supply = tokenB.totalSupply();

        _filler.fillWithoutData();

        assertEq(tokenB.totalSupply(), _supply - 950 ether, "950 B burned");
        assertEq(tokenB.balanceOf(fee), 50 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_ABranchWithoutActionSplitsTheBudget() public {
        CapitalTreePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA),
            _fork(NO_ACTION, 500_000, _deployTransfer(alice), 500_000, _deployTransfer(bob))
        );

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), 50 ether);
        assertEq(tokenA.balanceOf(bob), 50 ether);
    }

    function test_KeepIsAnExplicitLeaf() public {
        CapitalTreePlugin _plugin = _deployPlugin(budget, _chain(action, keep));
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND, "the proceeds stay in the treasury");
    }

    /// Above half the uint256 range, `balance + spend` overflows: the balance checks must not add
    /// A node and a budget without DAO actions don't call the DAO, and nothing is committed
    function test_EmptyActionListsSkipTheDao() public {
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _one(keep));

        vm.expectCall(address(dao), abi.encodeWithSelector(IExecutor.execute.selector), 0);
        vm.recordLogs();
        _plugin.trigger("", noData);

        Vm.Log[] memory _logs = vm.getRecordedLogs();
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].topics.length == 0) continue;
            assertTrue(_logs[i].topics[0] != CapitalTreePlugin.BudgetCommitted.selector, "nothing to commit");
        }
    }

    function test_AnUntouchedOfferAboveHalfTheRangePassesTheBalanceChecks() public {
        uint256 _huge = type(uint256).max / 2 + 1;
        deal(address(tokenA), address(dao), _huge, true);
        BalanceBudget _budget = _deployBalanceBudget(tokenA);
        OpenFillAction _action = OpenFillAction(
            ProxyLib.deployMinimalProxy(
                address(new OpenFillAction()),
                abi.encodeCall(OpenFillAction.initialize, (dao, _deps(address(_budget)), abi.encode(tokenB, DEMAND)))
            )
        );
        MockFiller _filler = new MockFiller(_deployPlugin(_budget, _chain(_action, keep)));
        _filler.setSkipOffer(true);
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenA.balanceOf(address(dao)), _huge, "the offer was not taken");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
    }

    /// Above half the uint256 range, `balance + input` overflows: a one-token node must not add them
    function test_AOneTokenFlowAboveHalfTheRangeRuns() public {
        uint256 _huge = type(uint256).max / 2 + 1;
        deal(address(tokenA), address(dao), _huge, true);
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _chain(_bad(BadAction.Mode.Pass), keep));

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(address(dao)), _huge);
    }

    function test_BudgetCommitsOnceAfterTheWholeTree() public {
        StreamBudget _budget = _deployBudget(RATE, 0);
        CapitalTreePlugin _plugin =
            _deployPlugin(_budget, _fork(NO_ACTION, 500_000, _deployTransfer(alice), 500_000, _deployTransfer(bob)));
        vm.warp(block.timestamp + EPOCH);

        _plugin.trigger("", noData);

        assertEq(_available(_budget), 0);
        assertEq(_budget.lastSeenBalance(), DAO_A - RATE, "the checkpoint sees the balance after both leaves");
    }

    /// A stream split between grants and an auction: the auction's offer grows at half the rate
    function test_ABranchSplitsTheStreamBetweenGrantsAndAnAuction() public {
        MockFiller _filler = new MockFiller(_deployPlugin(budget, _grantsAndAuction()));
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenA.balanceOf(alice), RATE / 2, "half the stream to grants");
        assertEq(tokenA.balanceOf(address(_filler)), RATE / 2, "half the stream on offer");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND, "the proceeds stay in the treasury");
        assertEq(_available(budget), 0, "the stream restarts for both");
    }

    /// The stream's cap, not the action, limits the offer
    function test_TheStreamCapLimitsTheOffer() public {
        StreamBudget _budget = _deployBudget(RATE, STREAM_CAP);
        MockFiller _filler = new MockFiller(_deployPlugin(_budget, _chain(_deployAction(_budget), keep)));
        tokenB.mint(address(_filler), DEMAND);
        vm.warp(block.timestamp + 5 * EPOCH); // 50 A streamed, capped at 20

        _filler.fillWithoutData();

        assertEq(tokenA.balanceOf(address(_filler)), STREAM_CAP, "the auction offers 20 A");
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - STREAM_CAP, "the rest never leaves the DAO");
        assertEq(_available(_budget), 0, "the stream restarts");
    }

    /// OpenFill offers whatever its parent passes on, wherever it sits
    function test_AnAuctionBelowAnActionOffersItsWholeInput() public {
        Node[] memory _tree = new Node[](3);
        (_tree[0], _tree[1], _tree[2]) = (_then(_bad(BadAction.Mode.Pass), 1), _then(action, 2), _leaf(keep));
        MockFiller _filler = new MockFiller(_deployPlugin(budget, _tree));
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenA.balanceOf(address(_filler)), RATE, "the filler gets the whole 10 A");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND, "the proceeds stay in the treasury");
    }

    function testFuzz_RevertWhen_FillerUnderDelivers(uint256 _shortfall) public {
        _shortfall = bound(_shortfall, 1, DEMAND);
        filler.setFillDelta(-int256(_shortfall));

        vm.expectRevert(
            abi.encodeWithSelector(OpenFillAction.DemandNotMet.selector, DAO_B + DEMAND, DAO_B + DEMAND - _shortfall)
        );
        filler.fill("");

        assertEq(_available(budget), RATE, "offer not consumed");
        assertEq(tokenA.balanceOf(address(dao)), DAO_A);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
        assertEq(tokenA.allowance(address(dao), address(filler)), 0);
    }

    // =========================================================================================
    // Forwarding the surplus
    // =========================================================================================

    /// Without forwardSurplus, arbitrary overpayments stay in the DAO.
    function testFuzz_ADeclaredNodePassesItsOutputAndKeepsTheSurplus(uint256 _surplus) public {
        _surplus = bound(_surplus, 0, 1_000_000 ether - DEMAND);
        filler.setFillDelta(int256(_surplus));

        filler.fill("");

        assertEq(tokenB.balanceOf(BURN), 950 ether, "95% of the demanded 1,000 B");
        assertEq(tokenB.balanceOf(fee), 50 ether, "5% of the demanded 1,000 B");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + _surplus, "the surplus stays in the treasury");
    }

    function testFuzz_TheNextNodeGetsEverythingTheFillerDelivers(uint128 _surplus) public {
        Node[] memory _tree = _chain(action, _deployTransfer(alice));
        _tree[0].forwardSurplus = true;
        MockFiller _filler = new MockFiller(_deployPlugin(budget, _tree));
        tokenB.mint(address(_filler), DEMAND + _surplus);
        _filler.setFillDelta(int256(uint256(_surplus)));

        _filler.fillWithoutData();

        assertEq(tokenB.balanceOf(alice), DEMAND + _surplus);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B, "no surplus left in the treasury");
    }

    function testFuzz_WeightsSplitEverythingTheFillerDelivers(uint128 _surplus) public {
        Node[] memory _tree = _splitToBurnAndFee(action);
        _tree[0].forwardSurplus = true;
        MockFiller _filler = new MockFiller(_deployPlugin(budget, _tree));
        tokenB.mint(address(_filler), DEMAND + _surplus);
        _filler.setFillDelta(int256(uint256(_surplus)));

        _filler.fillWithoutData();

        uint256 _fee = (DEMAND + _surplus) / 20;
        assertEq(tokenB.balanceOf(BURN), DEMAND + _surplus - _fee);
        assertEq(tokenB.balanceOf(fee), _fee);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    /// One token: the children get the whole input plus what came in
    function testFuzz_AOneTokenNodeForwardsItsInputAndItsIncome(uint128 _incomeAmount) public {
        Node[] memory _tree = _chain(_income(NO_TOKEN, _incomeAmount, 0, 0), _deployTransfer(alice));
        _tree[0].forwardSurplus = true;
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), DAO_A + _incomeAmount);
        assertEq(tokenA.balanceOf(address(dao)), 0);
    }

    function testFuzz_AOneTokenDeclaredNodeKeepsItsIncome(uint128 _incomeAmount) public {
        CapitalTreePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA), _chain(_income(NO_TOKEN, _incomeAmount, 0, 0), _deployTransfer(alice))
        );

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), DAO_A);
        assertEq(tokenA.balanceOf(address(dao)), _incomeAmount, "the income stays in the treasury");
    }

    /// With no declared minimum, forwarding still passes all received B to the children.
    function testFuzz_ATwoTokenNodeWithNoMinimumForwardsWhatArrived(uint128 _incomeAmount) public {
        _incomeAmount = uint128(bound(_incomeAmount, 1, type(uint128).max));
        Node[] memory _tree = _chain(_income(tokenB, _incomeAmount, 0, 0), _deployTransfer(alice));
        _tree[0].forwardSurplus = true;
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _plugin.trigger("", noData);

        assertEq(tokenB.balanceOf(alice), _incomeAmount);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A, "the A input wasn't spent");
    }

    function testFuzz_RevertWhen_AOneTokenForwardingNodeLosesTokens(uint256 _loss) public {
        _loss = bound(_loss, 1, DAO_A);
        Node[] memory _tree = _chain(_income(NO_TOKEN, 0, _loss, 0), keep);
        _tree[0].forwardSurplus = true;
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalTreePlugin.UnexpectedBalance.selector, 0, address(tokenA), DAO_A, DAO_A - _loss
            )
        );
        _plugin.trigger("", noData);
    }

    /// Income lets a one-token node declare more than its input; its child gets the declared amount
    function testFuzz_AOneTokenNodeMayDeclareMoreThanItsInput(uint128 _incomeAmount, uint128 _extra) public {
        _incomeAmount = uint128(bound(_incomeAmount, 1, type(uint128).max));
        _extra = uint128(bound(_extra, 1, _incomeAmount));
        CapitalTreePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA),
            _chain(_income(NO_TOKEN, _incomeAmount, 0, int256(uint256(_extra))), _deployTransfer(alice))
        );

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), DAO_A + _extra);
        assertEq(tokenA.balanceOf(address(dao)), _incomeAmount - _extra);
    }

    function testFuzz_RevertWhen_AOneTokenNodeDeclaresMoreThanArrived(uint128 _incomeAmount, uint128 _extra) public {
        _extra = uint128(bound(_extra, 1, type(uint128).max));
        _incomeAmount = uint128(bound(_incomeAmount, 0, _extra - 1));
        CapitalTreePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA), _chain(_income(NO_TOKEN, _incomeAmount, 0, int256(uint256(_extra))), keep)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalTreePlugin.UnexpectedBalance.selector, 0, address(tokenA), DAO_A + _extra, DAO_A + _incomeAmount
            )
        );
        _plugin.trigger("", noData);
    }

    /// A one-token node may lose exactly its input minus its output: 2 here, so losing 3 reverts
    function test_RevertWhen_AOneTokenNodeLosesMoreThanItsInputMinusItsOutput() public {
        CapitalTreePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(tokenA), _chain(_income(NO_TOKEN, 0, 3, -2), keep));

        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalTreePlugin.UnexpectedBalance.selector, 0, address(tokenA), DAO_A - 2, DAO_A - 3
            )
        );
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_ALeafForwardsSurplus() public {
        Node[] memory _tree = _chain(_bad(BadAction.Mode.Pass), keep);
        _tree[1].forwardSurplus = true;

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalTreePlugin.InvalidForwardSurplus.selector, 1));
    }

    function test_RevertWhen_ABranchWithoutActionForwardsSurplus() public {
        Node[] memory _tree = _fork(NO_ACTION, 500_000, keep, 500_000, keep);
        _tree[0].forwardSurplus = true;

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalTreePlugin.InvalidForwardSurplus.selector, 0));
    }

    function test_PreconditionsCanBlockANode() public {
        CapitalTreePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.Block), keep));

        vm.expectRevert(BadAction.Blocked.selector);
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_Paused() public {
        vm.prank(manager);
        plugin.pause();

        vm.expectRevert("Pausable: paused");
        filler.fill("");
    }

    function testFuzz_RevertWhen_DataLengthMismatch(uint256 _length) public {
        _length = bound(_length, 1, 64);
        if (_length == 3) _length = 4;
        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.DataLengthMismatch.selector, 3, _length));
        plugin.trigger("", new bytes[](_length));
    }

    /// Each action gets its node's entry, the same bytes in `build` and `preconditions`
    function testFuzz_EachActionGetsItsNodeData(bytes memory _keepData, address _beneficiary) public {
        vm.assume(_beneficiary != address(0) && _beneficiary != address(dao));
        uint256 _before = tokenA.balanceOf(_beneficiary);
        CapitalTreePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(tokenA), _fork(NO_ACTION, 500_000, keep, 500_000, toBeneficiary));
        bytes[] memory _data = new bytes[](3);
        _data[1] = _keepData;
        _data[2] = abi.encode(_beneficiary);
        Asset memory _half = Asset(tokenA, DAO_A / 2);

        vm.expectCall(address(keep), abi.encodeCall(INodeAction.build, (address(this), _keepData, _half)));
        vm.expectCall(address(toBeneficiary), abi.encodeCall(INodeAction.build, (address(this), _data[2], _half)));
        vm.expectCall(
            address(toBeneficiary),
            abi.encodeCall(INodeAction.preconditions, (address(this), _data[2], _half, Asset(tokenA, 0)))
        );
        _plugin.trigger("", _data);

        assertEq(tokenA.balanceOf(_beneficiary), _before + DAO_A / 2);
    }

    /// No node data: every action gets empty bytes
    function test_WithoutNodeDataActionsGetEmptyBytes() public {
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _one(keep));
        Asset memory _input = Asset(tokenA, DAO_A);

        vm.expectCall(address(keep), abi.encodeCall(INodeAction.build, (address(this), "", _input)));
        vm.expectCall(
            address(keep), abi.encodeCall(INodeAction.preconditions, (address(this), "", _input, Asset(tokenA, 0)))
        );
        _plugin.trigger("", noData);
    }

    // =========================================================================================
    // Every node must succeed
    // =========================================================================================

    function test_RevertWhen_TheBudgetIsEmpty() public {
        filler.fillWithoutData(); // the auction restarts at 0

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.EmptyInput.selector, 0));
        filler.fillWithoutData();
    }

    /// A node that can't be skipped must run, so a share that rounds to zero reverts the whole trigger
    function test_RevertWhen_AShareRoundsToZero() public {
        ERC20Mock _dust = new ERC20Mock("Dust", "D");
        _dust.mint(address(dao), 19); // 5% of 19 rounds to 0
        CapitalTreePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(IERC20(address(_dust))),
            _fork(NO_ACTION, 950_000, _deployTransfer(alice), 50_000, _deployTransfer(bob))
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.EmptyInput.selector, 2));
        _plugin.trigger("", noData);
    }

    /// The rounding remainder goes to the largest weight, so alice gets all 19
    function test_AShareThatRoundsToZeroIsSkippedWhenTheChildMaySkip() public {
        ERC20Mock _dust = new ERC20Mock("Dust", "D");
        _dust.mint(address(dao), 19);
        Node[] memory _tree = _fork(NO_ACTION, 950_000, _deployTransfer(alice), 50_000, _deployTransfer(bob));
        _tree[2].skipWhenEmpty = true;
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(IERC20(address(_dust))), _tree);

        _plugin.trigger("", noData);

        assertEq(_dust.balanceOf(alice), 19);
        assertEq(_dust.balanceOf(bob), 0);
    }

    /// Node 3 never runs: had it run on nothing, it would revert with EmptyInput
    function test_SkippingANodeSkipsEverythingBelowIt() public {
        Node[] memory _tree = new Node[](4);
        _tree[0] = _splitBy(_capSplitter(dao, DAO_A))[0];
        _tree[1] = _leaf(_deployTransfer(alice));
        _tree[2] = _then(_bad(BadAction.Mode.Pass), 3);
        _tree[2].skipWhenEmpty = true;
        _tree[3] = _leaf(keep);
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), DAO_A);
    }

    function test_RevertWhen_TheRootMaySkip() public {
        Node[] memory _tree = _one(keep);
        _tree[0].skipWhenEmpty = true;

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalTreePlugin.SkippableRoot.selector));
    }

    /// Its child then receives nothing
    function test_RevertWhen_TheRootOutputsNothing() public {
        CapitalTreePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.Skip), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.EmptyInput.selector, 1));
        _plugin.trigger("", noData);
    }

    /// A leaf below a branch without an action can't output anything either
    function test_RevertWhen_ALeafBelowABranchOutputsSomething() public {
        CapitalTreePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA), _fork(NO_ACTION, 500_000, _bad(BadAction.Mode.TakeHalf), 500_000, keep)
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.OutputWithoutChildren.selector, 1, DAO_A / 4));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_AChildOutputsNothing() public {
        CapitalTreePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA), _chain(_bad(BadAction.Mode.Pass), _bad(BadAction.Mode.Skip), keep)
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.EmptyInput.selector, 2));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_ALeafLeavesOutputBehind() public {
        MockSwapAction _swap = new MockSwapAction(new MockExchange(2e18), tokenB, address(dao));
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _one(_swap));

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.OutputWithoutChildren.selector, 0, 2 * DAO_A));
        _plugin.trigger("", noData);
    }

    // =========================================================================================
    // Splitters
    // =========================================================================================

    function test_ASplitterDividesABranchOutput() public {
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _splitBy(_capSplitter(dao, 30 ether)));

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), 30 ether);
        assertEq(tokenA.balanceOf(bob), DAO_A - 30 ether);
    }

    /// The splitter sees what the action produced: the 1,000 B of the fill
    function test_ASplitterDividesAnActionOutput() public {
        Node[] memory _tree = _splitBy(_capSplitter(dao, 100 ether));
        _tree[0].action = action;
        MockFiller _filler = new MockFiller(_deployPlugin(budget, _tree));
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenB.balanceOf(alice), 100 ether);
        assertEq(tokenB.balanceOf(bob), DEMAND - 100 ether);
    }

    /// The splitter sees the 1,050 B delivered, not the 1,000 B demanded
    function test_ASplitterDividesEverythingTheFillerDelivers() public {
        Node[] memory _tree = _splitBy(_capSplitter(dao, 100 ether));
        _tree[0].action = action;
        _tree[0].forwardSurplus = true;
        MockFiller _filler = new MockFiller(_deployPlugin(budget, _tree));
        tokenB.mint(address(_filler), DEMAND + 50 ether);
        _filler.setFillDelta(50 ether);

        _filler.fillWithoutData();

        assertEq(tokenB.balanceOf(alice), 100 ether);
        assertEq(tokenB.balanceOf(bob), DEMAND - 50 ether);
    }

    function test_ASplitterCanLeaveOutAChildThatMaySkip() public {
        Node[] memory _tree = _splitBy(_capSplitter(dao, DAO_A));
        _tree[2].skipWhenEmpty = true;
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), DAO_A);
        assertEq(tokenA.balanceOf(bob), 0);
    }

    function test_RevertWhen_ASplitterGivesNothingToAChildThatCannotSkip() public {
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _splitBy(_capSplitter(dao, DAO_A)));

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.EmptyInput.selector, 2));
        _plugin.trigger("", noData);
    }

    function testFuzz_RevertWhen_ASplitDoesNotAddUp(uint256 _shortfall) public {
        _shortfall = bound(_shortfall, 1, DAO_A / 2);
        uint256[] memory _amounts = new uint256[](2);
        (_amounts[0], _amounts[1]) = (DAO_A / 2, DAO_A / 2 - _shortfall);
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _splitBy(_fixedSplitter(_amounts)));

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.InvalidSplit.selector, 0));
        _plugin.trigger("", noData);
    }

    function testFuzz_RevertWhen_ASplitExceedsTheOutput(uint256 _excess) public {
        _excess = bound(_excess, 1, DAO_A);
        uint256[] memory _amounts = new uint256[](2);
        (_amounts[0], _amounts[1]) = (DAO_A / 2, DAO_A / 2 + _excess);
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _splitBy(_fixedSplitter(_amounts)));

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.InvalidSplit.selector, 0));
        _plugin.trigger("", noData);
    }

    function testFuzz_RevertWhen_ASplitHasTheWrongLength(uint256 _length) public {
        _length = bound(_length, 1, 64);
        if (_length == 2) _length = 3;
        uint256[] memory _amounts = new uint256[](_length);
        _amounts[0] = DAO_A;
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _splitBy(_fixedSplitter(_amounts)));

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.InvalidSplit.selector, 0));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_ASplitterIsNotOnABranch() public {
        Node[] memory _tree = _chain(_bad(BadAction.Mode.Pass), keep);
        _tree[0].splitter = _capSplitter(dao, 1);

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalTreePlugin.InvalidSplitter.selector, 0));
    }

    /// Weights for 3 children on a 2-child branch are rejected when the flow is set
    function test_RevertWhen_WeightsDoNotMatchTheChildren() public {
        uint32[] memory _weights = new uint32[](3);
        (_weights[0], _weights[1], _weights[2]) = (400_000, 300_000, 300_000);

        _expectInitRevert(
            budget,
            _splitBy(_deployWeightSplitter(_weights)),
            abi.encodeWithSelector(CapitalTreePlugin.InvalidSplitter.selector, 0)
        );
    }

    /// Weights for 2 children on a 3-child branch are rejected too
    function test_RevertWhen_WeightsAreForFewerChildren() public {
        uint32[] memory _weights = new uint32[](2);
        (_weights[0], _weights[1]) = (500_000, 500_000);
        Node[] memory _tree = new Node[](4);
        _tree[0].children = new uint32[](3);
        (_tree[0].children[0], _tree[0].children[1], _tree[0].children[2]) = (1, 2, 3);
        _tree[0].splitter = _deployWeightSplitter(_weights);
        (_tree[1], _tree[2], _tree[3]) = (_leaf(keep), _leaf(keep), _leaf(keep));

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalTreePlugin.InvalidSplitter.selector, 0));
    }

    function test_RevertWhen_ASplitterBelongsToAnotherDao() public {
        ISplitter _foreign = _capSplitter(IDAO(makeAddr("otherDao")), 1);

        _expectInitRevert(
            budget,
            _splitBy(_foreign),
            abi.encodeWithSelector(CapitalTreePlugin.ForeignComponent.selector, address(_foreign))
        );
    }

    // =========================================================================================
    // The parent's record
    // =========================================================================================

    /// A forwarding node's splitter shares everything that arrived: the 1,000 B demanded plus the 50 B surplus
    function test_ASplitterGetsTheNodesOutput() public {
        ISplitter _splitter = _capSplitter(dao, 100 ether);
        Node[] memory _tree = _splitBy(_splitter);
        _tree[0].action = action;
        _tree[0].forwardSurplus = true;
        MockFiller _filler = _overpayingFiller(_tree, 50 ether);

        vm.expectCall(
            address(_splitter), abi.encodeCall(ISplitter.split, (address(_filler), Asset(tokenB, DEMAND + 50 ether), 2))
        );
        _filler.fillWithoutData();
    }

    function test_NodeExecutedEmitsWhatTheChildrenGet() public {
        Node[] memory _tree = _chain(action, keep);
        _tree[0].forwardSurplus = true;
        MockFiller _filler = _overpayingFiller(_tree, 50 ether);

        _expectNodeExecuted(
            address(_filler.plugin()), address(_filler), Asset(tokenA, RATE), Asset(tokenB, DEMAND + 50 ether), 50 ether
        );
        _filler.fillWithoutData();
    }

    /// Without forwardSurplus the children get the 1,000 B demanded; the 50 B surplus stays in the DAO
    function test_ADeclaredNodePassesOnTheDeclaredAmount() public {
        MockFiller _filler = _overpayingFiller(_chain(action, keep), 50 ether);

        _expectNodeExecuted(
            address(_filler.plugin()), address(_filler), Asset(tokenA, RATE), Asset(tokenB, DEMAND), 50 ether
        );
        _filler.fillWithoutData();
    }

    /// With one token the input never left the DAO: paying 10 A and getting 20 A back passes on input + 10
    function test_AOneTokenForwardingNodePassesOnItsInputPlusTheNetChange() public {
        Node[] memory _tree = _chain(_income(NO_TOKEN, 20 ether, 10 ether, 0), keep);
        _tree[0].forwardSurplus = true;
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _expectNodeExecuted(
            address(_plugin), address(this), Asset(tokenA, DAO_A), Asset(tokenA, DAO_A + 10 ether), 10 ether
        );
        _plugin.trigger("", noData);
    }

    /// With one token, a node that pays a 2 A cost and declares the 98 A left has no surplus
    function test_AOneTokenNodeWithACostHasNoSurplus() public {
        Node[] memory _tree = _chain(_income(NO_TOKEN, 0, 2 ether, -2 ether), keep);
        _tree[0].forwardSurplus = true;
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _expectNodeExecuted(address(_plugin), address(this), Asset(tokenA, DAO_A), Asset(tokenA, DAO_A - 2 ether), 0);
        _plugin.trigger("", noData);
    }

    /// A keep leaf leaves its whole input in the DAO, but a leaf has no children: no surplus
    function test_ALeafReportsNoSurplus() public {
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _one(keep));

        _expectNodeExecuted(address(_plugin), address(this), Asset(tokenA, DAO_A), Asset(tokenA, 0), 0);
        _plugin.trigger("", noData);
    }

    /// Another token, none declared, no forwarding: the plugin doesn't read that token, so the 20 B
    /// that came in aren't reported
    function test_AnUnmeasuredOutputReportsNoSurplus() public {
        Node[] memory _tree = _chain(_income(tokenB, 20 ether, 0, 0), keep);
        _tree[1].skipWhenEmpty = true;
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _expectNodeExecuted(address(_plugin), address(this), Asset(tokenA, DAO_A), Asset(tokenB, 0), 0);
        _plugin.trigger("", noData);

        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 20 ether);
    }

    /// The last event of a run, after the budget's commit
    function test_FlowExecutedFollowsTheBudgetCommit() public {
        vm.expectEmit(address(plugin));
        emit CapitalTreePlugin.BudgetCommitted(_executionIdOf(address(plugin), 1, 3));
        vm.expectEmit(address(plugin));
        emit CapitalTreePlugin.FlowExecuted(address(filler), 1, Asset(tokenA, RATE));
        filler.fillWithoutData();
    }

    /// Without commit actions too, once per trigger, with that trigger's nonce
    function test_FlowExecutedIsEmittedOncePerTrigger() public {
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _one(keep));

        for (uint64 _nonce = 1; _nonce <= 2; ++_nonce) {
            vm.expectEmit(address(_plugin));
            emit CapitalTreePlugin.FlowExecuted(address(this), _nonce, Asset(tokenA, DAO_A));
            _plugin.trigger("", noData);
        }
    }

    /// Two fillers, or a solver batching triggers, in the same block: indexers can still tell them apart
    function test_TwoTriggersInOneBlockGetTheirOwnExecutionIds() public {
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _chain(_bad(BadAction.Mode.Pass), keep));

        bytes32 _first = _triggerAndGetRootExecutionId(_plugin);
        bytes32 _second = _triggerAndGetRootExecutionId(_plugin);

        assertTrue(_first != _second);
    }

    /// A branch without an action runs nothing: its splitter shares the input as it came
    function test_ABranchWithoutActionPassesOnItsInput() public {
        ISplitter _splitter = _capSplitter(dao, 30 ether);
        CapitalTreePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _splitBy(_splitter));

        vm.expectCall(address(_splitter), abi.encodeCall(ISplitter.split, (address(this), Asset(tokenA, DAO_A), 2)));
        _plugin.trigger("", noData);
    }

    // =========================================================================================
    // Guards
    // =========================================================================================

    function test_RevertWhen_AnActionTargetsTheDao() public {
        CapitalTreePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.TargetDao), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.ActionTargetsDao.selector, 0, 0));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_AnActionTargetsThePlugin() public {
        CapitalTreePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.TargetPlugin), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.ActionTargetsPlugin.selector, 0, 0));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_ACheckChangesState() public {
        WritingCheckAction _writer = new WritingCheckAction(address(dao));
        CapitalTreePlugin _plugin = _deployPlugin(budget, _chain(INodeAction(address(_writer)), keep));

        vm.expectRevert(); // the write fails in the static call, with no revert data
        _plugin.trigger("", noData);
    }

    function test_FillerCannotReenterTrigger() public {
        filler.setReenter(true);

        filler.fill("");

        assertEq(filler.reentryError(), abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"));
        assertEq(tokenB.balanceOf(BURN), 950 ether, "the outer fill still completes");
    }

    // =========================================================================================
    // Balance checks
    // =========================================================================================

    function test_RevertWhen_AnActionDeclaresOutputItNeverProduced() public {
        CapitalTreePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.Lie), keep));

        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalTreePlugin.UnexpectedBalance.selector, 0, address(tokenB), DAO_B + 10 ether, DAO_B
            )
        );
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_AnActionSpendsMoreThanItDeclared() public {
        CapitalTreePlugin _plugin = _deployPlugin(budget, _one(_bad(BadAction.Mode.Drain)));

        // The root declared RATE but moved twice that
        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalTreePlugin.UnexpectedBalance.selector, 0, address(tokenA), DAO_A - RATE, DAO_A - 2 * RATE
            )
        );
        _plugin.trigger("", noData);
    }

    /// A node is only checked on its own tokens: the budget check catches one spending the budget's token
    function test_RevertWhen_ANodeSpendsTheBudgetTokenItWasNotGiven() public {
        StreamBudget _budget = _deployStream(tokenB, RATE, 0);
        OpenFillAction _sell = _deployOpenFill(_budget, tokenA);
        MockFiller _filler = new MockFiller(_deployPlugin(_budget, _chain(_sell, _bad(BadAction.Mode.DrainB))));
        tokenA.mint(address(_filler), DEMAND);
        vm.warp(block.timestamp + EPOCH);

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.BudgetExceeded.selector, RATE, RATE + 1));
        _filler.fillWithoutData();
    }

    // =========================================================================================
    // Helpers
    // =========================================================================================

    function _bad(BadAction.Mode _mode) internal returns (INodeAction) {
        return new BadAction(_mode, address(dao), tokenB);
    }

    /// @dev A filler for a new plugin running `_tree` on the stream budget, paying `_extra` B above the demand
    function _overpayingFiller(Node[] memory _tree, uint256 _extra) internal returns (MockFiller _filler) {
        _filler = new MockFiller(_deployPlugin(budget, _tree));
        tokenB.mint(address(_filler), DEMAND + _extra);
        _filler.setFillDelta(int256(_extra));
    }

    /// @dev Triggers `_plugin` once and returns the execution ID its root (node 0) emitted
    function _triggerAndGetRootExecutionId(CapitalTreePlugin _plugin) internal returns (bytes32) {
        vm.recordLogs();
        _plugin.trigger("", noData);
        Vm.Log[] memory _logs = vm.getRecordedLogs();
        for (uint256 i; i < _logs.length; ++i) {
            bool _isRoot = _logs[i].emitter == address(_plugin)
                && _logs[i].topics[0] == CapitalTreePlugin.NodeExecuted.selector && uint256(_logs[i].topics[1]) == 0;
            // The execution ID is the first non-indexed field
            if (_isRoot) return abi.decode(_logs[i].data, (bytes32));
        }
        revert("no NodeExecuted for the root");
    }

    /// @dev The root (node 0) of `_plugin`'s first trigger emits exactly this input, output and surplus
    function _expectNodeExecuted(
        address _plugin,
        address _caller,
        Asset memory _input,
        Asset memory _output,
        uint256 _surplus
    ) internal {
        vm.expectEmit(_plugin);
        emit CapitalTreePlugin.NodeExecuted(0, _caller, _executionIdOf(_plugin, 1, 0), _input, _output, _surplus);
    }

    /// @dev The plugin's address, the trigger's nonce and the execution index, packed in 32 bytes
    function _executionIdOf(address _plugin, uint64 _nonce, uint32 _executionIndex) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(_plugin, _nonce, _executionIndex));
    }

    /// @dev An action that claims `_income` of `_outToken` (NO_TOKEN: its input token) and loses `_loss`
    function _income(IERC20 _outToken, uint256 _amount, uint256 _loss, int256 _extra) internal returns (INodeAction) {
        IncomeSource _source = new IncomeSource();
        // Fund the requested income, including amounts above the old fixed mock balance.
        uint256 _funding = _amount > 1_000 ether ? _amount : 1_000 ether;
        tokenA.mint(address(_source), _funding);
        tokenB.mint(address(_source), _funding);
        return new IncomeAction(_source, address(dao), _outToken, _amount, _loss, _extra);
    }

    /// @dev A branch without an action: 50% to alice (grants), 50% to the auction, whose proceeds are kept
    function _grantsAndAuction() internal returns (Node[] memory _tree) {
        _tree = new Node[](4);
        _tree[0] = _branch(NO_ACTION, 1, 500_000, 2, 500_000);
        _tree[1] = _leaf(_deployTransfer(alice));
        _tree[2] = _then(action, 3);
        _tree[3] = _leaf(keep);
    }

    /// @dev A branch without an action, divided by `_splitter` between transfers to alice and bob
    function _splitBy(ISplitter _splitter) internal returns (Node[] memory _tree) {
        _tree = new Node[](3);
        _tree[0].children = new uint32[](2);
        (_tree[0].children[0], _tree[0].children[1]) = (1, 2);
        _tree[0].splitter = _splitter;
        (_tree[1], _tree[2]) = (_leaf(_deployTransfer(alice)), _leaf(_deployTransfer(bob)));
    }

    function _capSplitter(IDAO _dao, uint256 _cap) internal returns (ISplitter) {
        return ISplitter(
            ProxyLib.deployMinimalProxy(
                address(new CapSplitter()), abi.encodeCall(CapSplitter.initialize, (_dao, _noDeps(), abi.encode(_cap)))
            )
        );
    }

    function _fixedSplitter(uint256[] memory _amounts) internal returns (ISplitter) {
        return ISplitter(
            ProxyLib.deployMinimalProxy(
                address(new FixedSplitter()), abi.encodeCall(FixedSplitter.initialize, (dao, _amounts))
            )
        );
    }

    function _expectInitRevert(IBudget _budget, Node[] memory _tree, bytes memory _error) internal {
        CapitalTreePlugin _plugin = CapitalTreePlugin(ProxyLib.deployMinimalProxy(address(new CapitalTreePlugin()), ""));
        vm.expectRevert(_error);
        _plugin.initialize(dao, _budget, _tree);
    }
}
