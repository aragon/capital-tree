// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {WeightSplitter} from "../src/splitters/WeightSplitter.sol";
import {Asset} from "../src/lib/types.sol";
import {RATIO_BASE, SET_SETTINGS_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract WeightSplitterTest is Fixture {
    address internal implementation = address(new WeightSplitter());

    function testFuzz_StoresTheWeights(uint32 _a) public {
        _a = uint32(bound(_a, 1, RATIO_BASE - 1));
        WeightSplitter _splitter = _deployWeightSplitter(_pair(_a, uint32(RATIO_BASE) - _a));
        assertEq(address(_splitter.dao()), address(dao));
        assertEq(_splitter.weights()[0], _a);
        assertEq(_splitter.weights()[1], RATIO_BASE - _a);
    }

    function test_IsMadeForOneChildPerWeight() public {
        assertEq(_deployWeightSplitter(_pair(700_000, 300_000)).childCount(), 2);
    }

    /// 10 by thirds floors to 3 each; the remainder goes to the largest weight
    function test_TheRemainderGoesToTheLargestWeight() public {
        uint32[] memory _weights = new uint32[](3);
        (_weights[0], _weights[1], _weights[2]) = (333_333, 333_334, 333_333);

        uint256[] memory _amounts = _deployWeightSplitter(_weights).split(address(this), _output(10), 3);

        assertEq(_amounts[0], 3);
        assertEq(_amounts[1], 4);
        assertEq(_amounts[2], 3);
    }

    function testFuzz_TheFirstLargestWeightTakesTheRemainderOnATie(uint128 _out) public {
        uint256[] memory _amounts =
            _deployWeightSplitter(_pair(500_000, 500_000)).split(address(this), _output(_out), 2);
        assertEq(_amounts[0], uint256(_out) / 2 + _out % 2);
        assertEq(_amounts[1], uint256(_out) / 2);
    }

    function testFuzz_AmountsAddUpToTheOutput(uint256 _out, uint32 _a, uint32 _b) public {
        _a = uint32(bound(_a, 1, RATIO_BASE - 2));
        _b = uint32(bound(_b, 1, RATIO_BASE - 1 - _a));
        uint32[] memory _weights = new uint32[](3);
        (_weights[0], _weights[1], _weights[2]) = (_a, _b, uint32(RATIO_BASE) - _a - _b);

        uint256[] memory _amounts = _deployWeightSplitter(_weights).split(address(this), _output(_out), 3);

        assertEq(_amounts.length, 3);
        assertEq(_amounts[0] + _amounts[1] + _amounts[2], _out);
        for (uint256 k; k < 3; ++k) {
            assertGe(_amounts[k], (_out / RATIO_BASE) * _weights[k] + ((_out % RATIO_BASE) * _weights[k]) / RATIO_BASE);
        }
    }

    /// Minimal input where `amount * weight` overflows for a valid 50/50 split; each share still fits uint256.
    function test_Regression_SplitOverflowsBeforeDivision() public {
        uint256 _out = type(uint256).max / 500_000 + 1;
        uint256[] memory _amounts =
            _deployWeightSplitter(_pair(500_000, 500_000)).split(address(this), _output(_out), 2);
        assertEq(_amounts[0], _out / 2 + _out % 2);
        assertEq(_amounts[1], _out / 2);
    }

    function test_RevertWhen_ThereIsOneWeight() public {
        uint32[] memory _weights = new uint32[](1);
        _weights[0] = uint32(RATIO_BASE);

        _expectInitRevert(_weights);
    }

    function test_RevertWhen_AWeightIsZero() public {
        _expectInitRevert(_pair(uint32(RATIO_BASE), 0));
    }

    function testFuzz_RevertWhen_WeightsDoNotSumTo100(uint32 _a, uint32 _b) public {
        vm.assume(uint256(_a) + _b != RATIO_BASE);
        _expectInitRevert(_pair(_a, _b));
    }

    function test_RevertWhen_TheImplementationIsInitialized() public {
        vm.expectRevert();
        WeightSplitter(implementation).initialize(dao, _noDeps(), abi.encode(_pair(500_000, 500_000)));
    }

    // Changing the weights

    function testFuzz_TheManagerChangesTheWeights(uint32 _a, uint128 _out) public {
        _a = uint32(bound(_a, 1, RATIO_BASE - 1));
        uint32 _b = uint32(RATIO_BASE) - _a;
        WeightSplitter _splitter = _deployWeightSplitter(_pair(700_000, 300_000));
        dao.grant(address(_splitter), manager, SET_SETTINGS_PERMISSION_ID);
        vm.expectEmit(address(_splitter));
        emit WeightSplitter.WeightsUpdated(_pair(_a, _b));
        vm.prank(manager);
        _splitter.setWeights(_pair(_a, _b));
        uint256[] memory _amounts = _splitter.split(address(this), _output(_out), 2);
        uint256 _first = uint256(_out) * _a / RATIO_BASE;
        uint256 _second = uint256(_out) * _b / RATIO_BASE;
        uint256 _dust = uint256(_out) - _first - _second;
        assertEq(_amounts[0], _first + (_a >= _b ? _dust : 0));
        assertEq(_amounts[1], _second + (_b > _a ? _dust : 0));
    }

    function test_RevertWhen_SettingWeightsWithoutPermission() public {
        WeightSplitter _splitter = _deployWeightSplitter(_pair(700_000, 300_000));

        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(_splitter), alice, SET_SETTINGS_PERMISSION_ID
            )
        );
        vm.prank(alice);
        _splitter.setWeights(_pair(250_000, 750_000));
    }

    function test_RevertWhen_NewWeightsAreInvalid() public {
        WeightSplitter _splitter = _deployWeightSplitter(_pair(700_000, 300_000));
        dao.grant(address(_splitter), manager, SET_SETTINGS_PERMISSION_ID);

        vm.expectRevert(WeightSplitter.InvalidWeights.selector);
        vm.prank(manager);
        _splitter.setWeights(_pair(600_000, 300_000));
    }

    function test_RevertWhen_NewWeightsChangeTheCount() public {
        WeightSplitter _splitter = _deployWeightSplitter(_pair(700_000, 300_000));
        dao.grant(address(_splitter), manager, SET_SETTINGS_PERMISSION_ID);
        uint32[] memory _three = new uint32[](3);
        (_three[0], _three[1], _three[2]) = (400_000, 300_000, 300_000);

        vm.expectRevert(abi.encodeWithSelector(WeightSplitter.WeightCountChanged.selector, 2, 3));
        vm.prank(manager);
        _splitter.setWeights(_three);
    }

    function test_RevertWhen_NewWeightsShrinkTheCount() public {
        uint32[] memory _three = new uint32[](3);
        (_three[0], _three[1], _three[2]) = (400_000, 300_000, 300_000);
        WeightSplitter _splitter = _deployWeightSplitter(_three);
        dao.grant(address(_splitter), manager, SET_SETTINGS_PERMISSION_ID);

        vm.expectRevert(abi.encodeWithSelector(WeightSplitter.WeightCountChanged.selector, 3, 2));
        vm.prank(manager);
        _splitter.setWeights(_pair(700_000, 300_000));
    }

    function _expectInitRevert(uint32[] memory _weights) internal {
        WeightSplitter _splitter = WeightSplitter(ProxyLib.deployMinimalProxy(implementation, ""));
        vm.expectRevert(WeightSplitter.InvalidWeights.selector);
        _splitter.initialize(dao, _noDeps(), abi.encode(_weights));
    }

    function _pair(uint32 _a, uint32 _b) internal pure returns (uint32[] memory _weights) {
        _weights = new uint32[](2);
        (_weights[0], _weights[1]) = (_a, _b);
    }

    function _output(uint256 _amount) internal pure returns (Asset memory) {
        return Asset(IERC20(address(1)), _amount);
    }
}
