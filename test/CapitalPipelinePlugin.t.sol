// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MerkleClaimBudget} from "../src/budgets/MerkleClaimBudget.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {IBudget} from "../src/interfaces/IBudget.sol";
import {INodeAction} from "../src/interfaces/INodeAction.sol";
import {ISplitter} from "../src/interfaces/ISplitter.sol";
import {Asset, Node} from "../src/lib/types.sol";
import {CONFIGURE_PERMISSION_ID, MANAGER_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockFiller} from "./mocks/MockFiller.sol";
import {MockExchange, MockSwapAction} from "./mocks/MockSwap.sol";
import {BadAction, WritingCheckAction} from "./mocks/BadComponents.sol";
import {CapSplitter, FixedSplitter} from "./mocks/MockSplitter.sol";
import {IncomeAction, IncomeSource} from "./mocks/MockIncome.sol";

contract CapitalPipelinePluginTest is Fixture {
    IERC20 internal constant NO_TOKEN = IERC20(address(0));

    FundedStreamBudget internal budget;
    OpenFillAction internal action;
    CapitalPipelinePlugin internal plugin;
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
        assertEq(_stored[0].weights[0], 950_000);
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
                DaoUnauthorized.selector, address(dao), address(plugin), address(this), MANAGER_PERMISSION_ID
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
        _expectInitRevert(
            IBudget(address(0)), _one(keep), abi.encodeWithSelector(CapitalPipelinePlugin.NoBudget.selector)
        );
    }

    function test_RevertWhen_NoNodes() public {
        _expectInitRevert(
            budget, new Node[](0), abi.encodeWithSelector(CapitalPipelinePlugin.InvalidNodeCount.selector, 0)
        );
    }

    function test_RevertWhen_TooManyNodes() public {
        Node[] memory _tree = new Node[](17);
        for (uint32 i; i < 16; ++i) {
            _tree[i] = _then(keep, i + 1);
        }
        _tree[16] = _leaf(keep);

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.InvalidNodeCount.selector, 17));
    }

    function test_RevertWhen_ALeafHasNoAction() public {
        _expectInitRevert(
            budget, _one(NO_ACTION), abi.encodeWithSelector(CapitalPipelinePlugin.MissingAction.selector, 0)
        );
    }

    function test_RevertWhen_AChildDoesNotComeAfterItsParent() public {
        Node[] memory _tree = new Node[](1);
        _tree[0] = _then(keep, 0);

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.InvalidChild.selector, 0, 0));
    }

    function test_RevertWhen_ANodeHasTwoParents() public {
        Node[] memory _tree = new Node[](3);
        (_tree[0], _tree[1], _tree[2]) = (_branch(NO_ACTION, 1, 500_000, 2, 500_000), _then(keep, 2), _leaf(keep));

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.InvalidChild.selector, 1, 2));
    }

    function test_RevertWhen_ANodeIsUnreachable() public {
        Node[] memory _tree = new Node[](2);
        (_tree[0], _tree[1]) = (_leaf(keep), _leaf(keep));

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.UnreachableNode.selector, 1));
    }

    function test_RevertWhen_WeightsDoNotSumTo100() public {
        _expectInitRevert(
            budget,
            _fork(NO_ACTION, 600_000, keep, 300_000, keep),
            abi.encodeWithSelector(CapitalPipelinePlugin.InvalidWeights.selector, 0)
        );
    }

    function test_RevertWhen_ABoundActionBelowTheRootUsesAnotherBudget() public {
        Node[] memory _tree = new Node[](4);
        _tree[0] = _branch(NO_ACTION, 1, 500_000, 2, 500_000);
        _tree[1] = _leaf(keep);
        _tree[2] = _then(action, 3);
        _tree[3] = _leaf(keep);

        _expectInitRevert(
            _deployBudget(RATE, 0), _tree, abi.encodeWithSelector(CapitalPipelinePlugin.BudgetMismatch.selector, 2)
        );
    }

    function test_RevertWhen_ANodeIsAnImplementation() public {
        KeepAction _implementation = new KeepAction();

        _expectInitRevert(
            budget,
            _one(_implementation),
            abi.encodeWithSelector(CapitalPipelinePlugin.ForeignComponent.selector, address(_implementation))
        );
    }

    function test_RevertWhen_ANodeBelongsToAnotherDao() public {
        KeepAction _foreign = _deployKeep(IDAO(makeAddr("otherDao")));

        _expectInitRevert(
            budget,
            _one(_foreign),
            abi.encodeWithSelector(CapitalPipelinePlugin.ForeignComponent.selector, address(_foreign))
        );
    }

    function test_RevertWhen_TheBudgetBelongsToAnotherDao() public {
        BalanceBudget _foreign = BalanceBudget(
            ProxyLib.deployMinimalProxy(
                address(new BalanceBudget()),
                abi.encodeCall(BalanceBudget.initialize, (IDAO(makeAddr("otherDao")), tokenA))
            )
        );

        _expectInitRevert(
            _foreign,
            _one(keep),
            abi.encodeWithSelector(CapitalPipelinePlugin.ForeignComponent.selector, address(_foreign))
        );
    }

    function test_RevertWhen_TheRootIsBoundToAnotherBudget() public {
        _expectInitRevert(
            _deployBudget(RATE, 0),
            _chain(action, keep),
            abi.encodeWithSelector(CapitalPipelinePlugin.BudgetMismatch.selector, 0)
        );
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
        CapitalPipelinePlugin _plugin =
            _deployPlugin(budget, _fork(action, 950_000, burn, 50_000, _deployTransfer(fee)));
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), DEMAND);
        uint256 _supply = tokenB.totalSupply();

        _filler.fillWithoutData();

        assertEq(tokenB.totalSupply(), _supply - 950 ether, "950 B burned");
        assertEq(tokenB.balanceOf(fee), 50 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_ABranchWithoutActionSplitsTheBudget() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA),
            _fork(NO_ACTION, 500_000, _deployTransfer(alice), 500_000, _deployTransfer(bob))
        );

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), 50 ether);
        assertEq(tokenA.balanceOf(bob), 50 ether);
    }

    function test_KeepIsAnExplicitLeaf() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(action, keep));
        MockFiller _filler = new MockFiller(_plugin);
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND, "the proceeds stay in the treasury");
    }

    function test_BudgetCommitsOnceAfterTheWholeTree() public {
        FundedStreamBudget _budget = _deployBudget(RATE, 0);
        CapitalPipelinePlugin _plugin =
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
        FundedStreamBudget _budget = _deployBudget(RATE, STREAM_CAP);
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

    function test_RevertWhen_FillerUnderDelivers() public {
        filler.setFillDelta(-1);

        vm.expectRevert(
            abi.encodeWithSelector(OpenFillAction.DemandNotMet.selector, DAO_B + DEMAND, DAO_B + DEMAND - 1)
        );
        filler.fill("");

        assertEq(_available(budget), RATE, "offer not consumed");
    }

    // =========================================================================================
    // Forwarding the surplus
    // =========================================================================================

    /// The filler sends 100 B above the demand. Without forwardSurplus they stay in the DAO.
    function test_ADeclaredNodePassesItsOutputAndKeepsTheSurplus() public {
        filler.setFillDelta(100 ether);

        filler.fill("");

        assertEq(tokenB.balanceOf(BURN), 950 ether, "95% of the demanded 1,000 B");
        assertEq(tokenB.balanceOf(fee), 50 ether, "5% of the demanded 1,000 B");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 100 ether, "the surplus stays in the treasury");
    }

    function test_TheNextNodeGetsEverythingTheFillerDelivers() public {
        Node[] memory _tree = _chain(action, _deployTransfer(alice));
        _tree[0].forwardSurplus = true;
        MockFiller _filler = new MockFiller(_deployPlugin(budget, _tree));
        tokenB.mint(address(_filler), DEMAND + 1 ether);
        _filler.setFillDelta(1 ether);

        _filler.fillWithoutData();

        assertEq(tokenB.balanceOf(alice), DEMAND + 1 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B, "no surplus left in the treasury");
    }

    function test_WeightsSplitEverythingTheFillerDelivers() public {
        Node[] memory _tree = _splitToBurnAndFee(action);
        _tree[0].forwardSurplus = true;
        MockFiller _filler = new MockFiller(_deployPlugin(budget, _tree));
        tokenB.mint(address(_filler), DEMAND + 100 ether);
        _filler.setFillDelta(100 ether);

        _filler.fillWithoutData();

        assertEq(tokenB.balanceOf(BURN), 1045 ether, "95% of 1,100 B");
        assertEq(tokenB.balanceOf(fee), 55 ether, "5% of 1,100 B");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    /// One token: the children get the whole input plus what came in
    function test_AOneTokenNodeForwardsItsInputAndItsIncome() public {
        Node[] memory _tree = _chain(_income(NO_TOKEN, 3 ether, 0, 0), _deployTransfer(alice));
        _tree[0].forwardSurplus = true;
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), DAO_A + 3 ether);
        assertEq(tokenA.balanceOf(address(dao)), 0);
    }

    function test_AOneTokenDeclaredNodeKeepsItsIncome() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA), _chain(_income(NO_TOKEN, 3 ether, 0, 0), _deployTransfer(alice))
        );

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), DAO_A);
        assertEq(tokenA.balanceOf(address(dao)), 3 ether, "the income stays in the treasury");
    }

    /// The action can't promise any B, so it declares 0. The children still get the 20 B that came in.
    function test_ATwoTokenNodeWithNoMinimumForwardsWhatArrived() public {
        Node[] memory _tree = _chain(_income(tokenB, 20 ether, 0, 0), _deployTransfer(alice));
        _tree[0].forwardSurplus = true;
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _plugin.trigger("", noData);

        assertEq(tokenB.balanceOf(alice), 20 ether);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A, "the A input wasn't spent");
    }

    function test_RevertWhen_AOneTokenForwardingNodeLosesTokens() public {
        Node[] memory _tree = _chain(_income(NO_TOKEN, 0, 1 ether, 0), keep);
        _tree[0].forwardSurplus = true;
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalPipelinePlugin.UnexpectedBalance.selector, 0, address(tokenA), DAO_A, DAO_A - 1 ether
            )
        );
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_ALeafForwardsSurplus() public {
        Node[] memory _tree = _chain(_bad(BadAction.Mode.Pass), keep);
        _tree[1].forwardSurplus = true;

        _expectInitRevert(
            budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.InvalidForwardSurplus.selector, 1)
        );
    }

    function test_RevertWhen_ABranchWithoutActionForwardsSurplus() public {
        Node[] memory _tree = _fork(NO_ACTION, 500_000, keep, 500_000, keep);
        _tree[0].forwardSurplus = true;

        _expectInitRevert(
            budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.InvalidForwardSurplus.selector, 0)
        );
    }

    function test_PreconditionsCanBlockANode() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.Block), keep));

        vm.expectRevert(BadAction.Blocked.selector);
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_Paused() public {
        vm.prank(manager);
        plugin.pause();

        vm.expectRevert("Pausable: paused");
        filler.fill("");
    }

    function test_RevertWhen_DataLengthMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.DataLengthMismatch.selector, 3, 1));
        plugin.trigger("", new bytes[](1));
    }

    // =========================================================================================
    // Every node must succeed
    // =========================================================================================

    function test_RevertWhen_TheBudgetIsEmpty() public {
        filler.fillWithoutData(); // the auction restarts at 0

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.EmptyInput.selector, 0));
        filler.fillWithoutData();
    }

    /// A node that can't be skipped must run, so a share that rounds to zero reverts the whole trigger
    function test_RevertWhen_AShareRoundsToZero() public {
        ERC20Mock _dust = new ERC20Mock("Dust", "D");
        _dust.mint(address(dao), 19); // 5% of 19 rounds to 0
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(IERC20(address(_dust))),
            _fork(NO_ACTION, 950_000, _deployTransfer(alice), 50_000, _deployTransfer(bob))
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.EmptyInput.selector, 2));
        _plugin.trigger("", noData);
    }

    /// The rounding remainder goes to the largest weight, so alice gets all 19
    function test_AShareThatRoundsToZeroIsSkippedWhenTheChildMaySkip() public {
        ERC20Mock _dust = new ERC20Mock("Dust", "D");
        _dust.mint(address(dao), 19);
        Node[] memory _tree = _fork(NO_ACTION, 950_000, _deployTransfer(alice), 50_000, _deployTransfer(bob));
        _tree[2].skipWhenEmpty = true;
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(IERC20(address(_dust))), _tree);

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
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), DAO_A);
    }

    function test_RevertWhen_TheRootMaySkip() public {
        Node[] memory _tree = _one(keep);
        _tree[0].skipWhenEmpty = true;

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.SkippableRoot.selector));
    }

    function test_RevertWhen_TheRootTakesNothing() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.Skip), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NodeIncomplete.selector, 0, 0, RATE));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_TheRootTakesPartOfItsInput() public {
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(tokenA), _chain(_bad(BadAction.Mode.TakeHalf), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NodeIncomplete.selector, 0, DAO_A / 2, DAO_A));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_AChildTakesPartOfItsInput() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA), _chain(_bad(BadAction.Mode.Pass), _bad(BadAction.Mode.TakeHalf), keep)
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NodeIncomplete.selector, 1, DAO_A / 2, DAO_A));
        _plugin.trigger("", noData);
    }

    /// Only the root may take part of its input, even below a branch without an action
    function test_RevertWhen_ANodeBelowABranchTakesPartOfItsInput() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA), _fork(NO_ACTION, 500_000, _bad(BadAction.Mode.TakeHalf), 500_000, keep)
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NodeIncomplete.selector, 1, DAO_A / 4, DAO_A / 2));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_AChildSkips() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA), _chain(_bad(BadAction.Mode.Pass), _bad(BadAction.Mode.Skip), keep)
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NodeIncomplete.selector, 1, 0, DAO_A));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_ALeafLeavesOutputBehind() public {
        MockSwapAction _swap = new MockSwapAction(new MockExchange(2e18), tokenB, address(dao));
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _one(_swap));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.OutputWithoutChildren.selector, 0, 2 * DAO_A));
        _plugin.trigger("", noData);
    }

    // =========================================================================================
    // Splitters
    // =========================================================================================

    function test_ASplitterDividesABranchOutput() public {
        CapitalPipelinePlugin _plugin =
            _deployPlugin(_deployBalanceBudget(tokenA), _splitBy(_capSplitter(dao, 30 ether)));

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
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), DAO_A);
        assertEq(tokenA.balanceOf(bob), 0);
    }

    function test_RevertWhen_ASplitterGivesNothingToAChildThatCannotSkip() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _splitBy(_capSplitter(dao, DAO_A)));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.EmptyInput.selector, 2));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_ASplitDoesNotAddUp() public {
        uint256[] memory _amounts = new uint256[](2);
        (_amounts[0], _amounts[1]) = (DAO_A / 2, DAO_A / 2 - 1);
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _splitBy(_fixedSplitter(_amounts)));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.InvalidSplit.selector, 0));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_ASplitHasTheWrongLength() public {
        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = DAO_A;
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _splitBy(_fixedSplitter(_amounts)));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.InvalidSplit.selector, 0));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_ASplitterIsNotOnABranch() public {
        Node[] memory _tree = _chain(_bad(BadAction.Mode.Pass), keep);
        _tree[0].splitter = _capSplitter(dao, 1);

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.InvalidSplitter.selector, 0));
    }

    function test_RevertWhen_ASplitterComesWithWeights() public {
        Node[] memory _tree = _fork(NO_ACTION, 500_000, keep, 500_000, keep);
        _tree[0].splitter = _capSplitter(dao, 1);

        _expectInitRevert(budget, _tree, abi.encodeWithSelector(CapitalPipelinePlugin.InvalidSplitter.selector, 0));
    }

    function test_RevertWhen_ASplitterBelongsToAnotherDao() public {
        ISplitter _foreign = _capSplitter(IDAO(makeAddr("otherDao")), 1);

        _expectInitRevert(
            budget,
            _splitBy(_foreign),
            abi.encodeWithSelector(CapitalPipelinePlugin.ForeignComponent.selector, address(_foreign))
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
            address(_filler.plugin()), address(_filler), Asset(tokenA, RATE), Asset(tokenB, DEMAND + 50 ether)
        );
        _filler.fillWithoutData();
    }

    /// Without forwardSurplus the children get the 1,000 B demanded; the 50 B surplus stays in the DAO
    function test_ADeclaredNodePassesOnTheDeclaredAmount() public {
        MockFiller _filler = _overpayingFiller(_chain(action, keep), 50 ether);

        _expectNodeExecuted(address(_filler.plugin()), address(_filler), Asset(tokenA, RATE), Asset(tokenB, DEMAND));
        _filler.fillWithoutData();
    }

    /// With one token the input never left the DAO: paying 10 A and getting 20 A back passes on input + 10
    function test_AOneTokenForwardingNodePassesOnItsInputPlusTheNetChange() public {
        Node[] memory _tree = _chain(_income(NO_TOKEN, 20 ether, 10 ether, 0), keep);
        _tree[0].forwardSurplus = true;
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _tree);

        _expectNodeExecuted(address(_plugin), address(this), Asset(tokenA, DAO_A), Asset(tokenA, DAO_A + 10 ether));
        _plugin.trigger("", noData);
    }

    /// A branch without an action runs nothing: its splitter shares the input as it came
    function test_ABranchWithoutActionPassesOnItsInput() public {
        ISplitter _splitter = _capSplitter(dao, 30 ether);
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _splitBy(_splitter));

        vm.expectCall(address(_splitter), abi.encodeCall(ISplitter.split, (address(this), Asset(tokenA, DAO_A), 2)));
        _plugin.trigger("", noData);
    }

    // =========================================================================================
    // Guards
    // =========================================================================================

    function test_RevertWhen_AnActionTargetsTheDao() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.TargetDao), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.ActionTargetsDao.selector, 0, 0));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_AnActionTargetsThePlugin() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.TargetPlugin), keep));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.ActionTargetsPlugin.selector, 0, 0));
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_ACheckChangesState() public {
        WritingCheckAction _writer = new WritingCheckAction(address(dao));
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(INodeAction(address(_writer)), keep));

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
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _chain(_bad(BadAction.Mode.Lie), keep));

        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalPipelinePlugin.UnexpectedBalance.selector, 0, address(tokenB), DAO_B + 10 ether, DAO_B
            )
        );
        _plugin.trigger("", noData);
    }

    function test_RevertWhen_AnActionSpendsMoreThanItDeclared() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(budget, _one(_bad(BadAction.Mode.Drain)));

        // The root declared RATE but moved twice that
        vm.expectRevert(
            abi.encodeWithSelector(
                CapitalPipelinePlugin.UnexpectedBalance.selector, 0, address(tokenA), DAO_A - RATE, DAO_A - 2 * RATE
            )
        );
        _plugin.trigger("", noData);
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

    /// @dev The root (node 0) of `_plugin`'s next trigger, in this block, emits exactly this input and output
    function _expectNodeExecuted(address _plugin, address _caller, Asset memory _input, Asset memory _output)
        internal
    {
        bytes32 _executionId = keccak256(abi.encode(_plugin, block.timestamp, uint256(0)));
        vm.expectEmit(_plugin);
        emit CapitalPipelinePlugin.NodeExecuted(0, _caller, _executionId, _input, _output);
    }

    /// @dev An action that claims `_income` of `_outToken` (NO_TOKEN: its input token) and loses `_loss`
    function _income(IERC20 _outToken, uint256 _amount, uint256 _loss, int256 _extra) internal returns (INodeAction) {
        IncomeSource _source = new IncomeSource();
        tokenA.mint(address(_source), 1_000 ether);
        tokenB.mint(address(_source), 1_000 ether);
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
                address(new CapSplitter()), abi.encodeCall(CapSplitter.initialize, (_dao, _cap))
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
        CapitalPipelinePlugin _plugin =
            CapitalPipelinePlugin(ProxyLib.deployMinimalProxy(address(new CapitalPipelinePlugin()), ""));
        vm.expectRevert(_error);
        _plugin.initialize(dao, _budget, _tree);
    }
}
