// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";
import {IComponent} from "../interfaces/IComponent.sol";
import {Asset} from "../lib/types.sol";
import {RATIO_BASE, SET_SETTINGS_PERMISSION_ID} from "../lib/constants.sol";

/// @title WeightSplitter
/// @notice Splits a branch's output by weights: one per child, in the node's child order, each
///         non-zero, summing to RATIO_BASE. The rounding remainder goes to the largest weight.
///         Holders of SET_SETTINGS_PERMISSION_ID can change them.
contract WeightSplitter is ISplitter, IComponent, DaoAuthorizableUpgradeable {
    uint32[] internal _weights;

    event WeightsUpdated(uint32[] weights);

    error InvalidWeights();
    error WeightCountChanged(uint256 count, uint256 newCount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _dao The DAO the splitter works for
    /// @param _settings `abi.encode(uint32[] weights)`: one non-zero weight per child, summing to RATIO_BASE
    function initialize(IDAO _dao, address[] calldata, bytes calldata _settings) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
        _setWeights(abi.decode(_settings, (uint32[])));
    }

    /// @notice Replaces the weights from the next trigger on
    /// @dev Keeps their number: the node's children only change with `setFlow`
    function setWeights(uint32[] calldata _newWeights) external auth(SET_SETTINGS_PERMISSION_ID) {
        if (_newWeights.length != _weights.length) revert WeightCountChanged(_weights.length, _newWeights.length);
        _setWeights(_newWeights);
    }

    function weights() external view returns (uint32[] memory) {
        return _weights;
    }

    /// @inheritdoc ISplitter
    /// @dev One child per weight; `setWeights` keeps their number
    function childCount() external view returns (uint256) {
        return _weights.length;
    }

    /// @inheritdoc ISplitter
    /// @dev Returns one amount per weight and ignores the child count. A weight count that doesn't
    ///      match the node's children reverts in the plugin: in `_checkNode` (`InvalidSplitter`) when
    ///      the flow is set, and in `_split` (`InvalidSplit`) on a trigger.
    function split(address, Asset calldata _output, uint256) external view returns (uint256[] memory _amounts) {
        uint32[] memory _w = _weights;
        uint256 _count = _w.length;
        _amounts = new uint256[](_count);

        uint256 _assigned;
        uint256 _largest;
        for (uint256 k; k < _count; ++k) {
            _amounts[k] = (_output.amount * _w[k]) / RATIO_BASE;
            _assigned += _amounts[k];
            if (_w[k] > _w[_largest]) _largest = k;
        }
        _amounts[_largest] += _output.amount - _assigned;
    }

    function _setWeights(uint32[] memory _newWeights) internal {
        if (_newWeights.length < 2) revert InvalidWeights();
        uint256 _sum;
        for (uint256 k; k < _newWeights.length; ++k) {
            if (_newWeights[k] == 0) revert InvalidWeights();
            _sum += _newWeights[k];
        }
        if (_sum != RATIO_BASE) revert InvalidWeights();

        _weights = _newWeights;
        emit WeightsUpdated(_newWeights);
    }
}
