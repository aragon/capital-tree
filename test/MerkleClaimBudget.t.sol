// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalTreePlugin} from "../src/CapitalTreePlugin.sol";
import {MerkleClaimBudget} from "../src/budgets/MerkleClaimBudget.sol";
import {Node} from "../src/lib/types.sol";
import {SET_SETTINGS_PERMISSION_ID, RECORD_CLAIM_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MockExchange, MockSwapAction} from "./mocks/MockSwap.sol";
import {BadAction} from "./mocks/BadComponents.sol";

/// @notice Two-leaf tree: alice is owed 10 A, bob 30 A (cumulative)
contract MerkleClaimBudgetTest is Fixture {
    uint256 internal aliceAmount;
    uint256 internal bobAmount;

    MerkleClaimBudget internal merkle;
    CapitalTreePlugin internal plugin;

    function setUp() public override {
        super.setUp();
        merkle = _deployMerkle(tokenA, _root(10 ether, 30 ether));
        plugin = _deployPlugin(merkle, _one(toBeneficiary));
    }

    function test_AvailableIsWhatTheAccountIsOwed() public view {
        assertEq(merkle.available(alice, _claim(alice, 10 ether)), 10 ether);
    }

    function test_CommitRecordsTheClaim() public view {
        Action[] memory _actions = merkle.commitActions(alice, _claim(alice, 10 ether));

        assertEq(_actions.length, 1);
        assertEq(_actions[0].to, address(merkle));
        assertEq(_actions[0].data, abi.encodeCall(merkle.recordClaim, (alice, 10 ether)));
    }

    function test_AccountClaimsItsAmount() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether), _payTo(alice, 1));

        assertEq(tokenA.balanceOf(alice), 10 ether);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - 10 ether);
        assertEq(merkle.claimed(alice), 10 ether);
    }

    function test_RevertWhen_ClaimingAgain() public {
        vm.startPrank(alice);
        plugin.trigger(_claim(alice, 10 ether), _payTo(alice, 1));

        vm.expectRevert(MerkleClaimBudget.NothingToClaim.selector);
        plugin.trigger(_claim(alice, 10 ether), _payTo(alice, 1));
        vm.stopPrank();
    }

    function test_RevertWhen_SomeoneElseClaims() public {
        vm.expectRevert(MerkleClaimBudget.NotTheAccount.selector);
        vm.prank(carol);
        plugin.trigger(_claim(alice, 10 ether), _payTo(carol, 1));
    }

    /// The account names who gets paid in the payout leaf's data
    function test_AccountRedirectsToAnotherBeneficiary() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether), _payTo(carol, 1));

        assertEq(tokenA.balanceOf(carol), 10 ether);
        assertEq(tokenA.balanceOf(alice), 0);
    }

    function test_RevertWhen_ProofIsInvalid() public {
        vm.expectRevert(MerkleClaimBudget.InvalidProof.selector);
        vm.prank(alice);
        plugin.trigger(_claim(alice, 20 ether), _payTo(alice, 1)); // the tree says 10
    }

    function test_NewRootPaysTheDifference() public {
        vm.prank(alice);
        plugin.trigger(_claim(alice, 10 ether), _payTo(alice, 1));

        vm.prank(manager);
        merkle.setRoot(_root(25 ether, 30 ether));

        vm.prank(alice);
        plugin.trigger(_claim(alice, 25 ether), _payTo(alice, 1));

        assertEq(tokenA.balanceOf(alice), 25 ether, "10 in round one, 15 more in round two");
    }

    function test_RevertWhen_SetRootUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(merkle), address(this), SET_SETTINGS_PERMISSION_ID
            )
        );
        merkle.setRoot(bytes32(0));
    }

    function test_RevertWhen_RecordClaimUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(merkle), address(this), RECORD_CLAIM_PERMISSION_ID
            )
        );
        merkle.recordClaim(alice, 10 ether);
    }

    function test_RevertWhen_TokenHasNoCode() public {
        MerkleClaimBudget _merkle = MerkleClaimBudget(ProxyLib.deployMinimalProxy(address(new MerkleClaimBudget()), ""));
        vm.expectRevert(MerkleClaimBudget.InvalidToken.selector);
        _merkle.initialize(dao, _noDeps(), abi.encode(IERC20(address(0xBEEF)), bytes32(0)));
    }

    /// The payout fails, so the whole claim reverts
    function test_RevertWhen_TheDaoCannotPay() public {
        vm.prank(manager);
        merkle.setRoot(_root(1_000 ether, 30 ether));

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 0));
        vm.prank(alice);
        plugin.trigger(_claim(alice, 1_000 ether), _payTo(alice, 1));
    }

    /// Claim → swap A to B at 2 → pay the beneficiary (redirected to carol)
    function test_ClaimThenSwap() public {
        CapitalTreePlugin _plugin = _deployPlugin(merkle, _chain(_swap(), toBeneficiary));

        vm.prank(alice);
        _plugin.trigger(_claim(alice, 10 ether), _payTo(carol, 2));

        assertEq(tokenB.balanceOf(carol), 20 ether);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - 10 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B, "treasury B untouched");
    }

    /// A branch at the root splits the claim itself: 1% to the fee address, 99% swapped and paid to alice
    function test_ClaimWithAFeeBranch() public {
        Node[] memory _tree = new Node[](4);
        _tree[0] = _branch(NO_ACTION, 1, 10_000, 2, 990_000);
        _tree[1] = _leaf(_deployTransfer(fee));
        _tree[2] = _then(_swap(), 3);
        _tree[3] = _leaf(toBeneficiary);
        CapitalTreePlugin _plugin = _deployPlugin(merkle, _tree);

        vm.prank(alice);
        _plugin.trigger(_claim(alice, 10 ether), _payTo(alice, 4));

        assertEq(tokenA.balanceOf(fee), 0.1 ether);
        assertEq(tokenB.balanceOf(alice), 19.8 ether);
    }

    /// If a node can't run, the whole claim reverts and stays claimable
    function test_ClaimStaysOpenWhenANodeCannotRun() public {
        CapitalTreePlugin _plugin =
            _deployPlugin(merkle, _chain(new BadAction(BadAction.Mode.Skip, address(dao), tokenB), toBeneficiary));

        // The root outputs nothing, so its child receives nothing
        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.EmptyInput.selector, 1));
        vm.prank(alice);
        _plugin.trigger(_claim(alice, 10 ether), _payTo(alice, 2));

        assertEq(merkle.claimed(alice), 0, "nothing recorded");
    }

    // Helpers

    function _swap() internal returns (MockSwapAction) {
        MockExchange _exchange = new MockExchange(2e18);
        tokenB.mint(address(_exchange), 1_000 ether);
        return new MockSwapAction(_exchange, tokenB, address(dao));
    }

    function _leafHash(address _account, uint256 _cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }

    /// @dev OpenZeppelin MerkleProof hashes sorted pairs
    function _hashPair(bytes32 _a, bytes32 _b) internal pure returns (bytes32) {
        return _a < _b ? keccak256(abi.encode(_a, _b)) : keccak256(abi.encode(_b, _a));
    }

    function _root(uint256 _alice, uint256 _bob) internal returns (bytes32) {
        (aliceAmount, bobAmount) = (_alice, _bob);
        return _hashPair(_leafHash(alice, _alice), _leafHash(bob, _bob));
    }

    /// @dev The trigger's budget data. In a two-leaf tree, the proof is the other leaf.
    function _claim(address _account, uint256 _cumulative) internal view returns (bytes memory) {
        bytes32[] memory _proof = new bytes32[](1);
        _proof[0] = _account == alice ? _leafHash(bob, bobAmount) : _leafHash(alice, aliceAmount);
        return abi.encode(_account, _cumulative, _proof);
    }

    /// @dev Node data for a flow of `_nodes` nodes whose last node is the payout leaf, paying `_to`
    function _payTo(address _to, uint256 _nodes) internal pure returns (bytes[] memory _data) {
        _data = new bytes[](_nodes);
        _data[_nodes - 1] = abi.encode(_to);
    }
}
