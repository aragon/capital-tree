// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {WeightSplitter} from "../../../src/splitters/WeightSplitter.sol";
import {RATIO_BASE, SET_SETTINGS_PERMISSION_ID} from "../../../src/lib/constants.sol";

/// @notice What every invariant handler shares: the DAO, who administers it, and component deployment
abstract contract BaseHandler is Test {
    DAO internal dao;
    address internal root; // holds ROOT on the DAO, to grant permissions on new components
    address internal manager;
    address internal splitterImpl;

    constructor(DAO _dao, address _root, address _manager) {
        (dao, root, manager) = (_dao, _root, _manager);
        splitterImpl = address(new WeightSplitter());
    }

    /// @dev A weight splitter of the DAO, whose weights the manager can change
    function _deploySplitter(uint32[] memory _w) internal returns (WeightSplitter _splitter) {
        _splitter = WeightSplitter(
            ProxyLib.deployMinimalProxy(
                splitterImpl, abi.encodeCall(WeightSplitter.initialize, (dao, new address[](0), abi.encode(_w)))
            )
        );
        vm.prank(root);
        dao.grant(address(_splitter), manager, SET_SETTINGS_PERMISSION_ID);
    }

    /// @dev What a weight splitter should give each child: each share rounds down, and the remainder
    ///      goes to the first of the largest weights
    function _split(uint256 _amount, uint32[] memory _w) internal pure returns (uint256[] memory _amounts) {
        _amounts = new uint256[](_w.length);
        uint256 _largest;
        uint256 _sum;
        for (uint256 k; k < _w.length; ++k) {
            _amounts[k] = _amount * _w[k] / RATIO_BASE;
            _sum += _amounts[k];
            if (_w[k] > _w[_largest]) _largest = k;
        }
        _amounts[_largest] += _amount - _sum;
    }

    /// @dev `_n` non-zero weights summing to RATIO_BASE
    function _randomWeights(uint256 _n, uint256 _seed) internal pure returns (uint32[] memory _w) {
        _w = new uint32[](_n);
        uint256 _left = RATIO_BASE;
        for (uint256 k; k < _n - 1; ++k) {
            _seed = uint256(keccak256(abi.encode(_seed, k)));
            // Leave at least 1 for each child still to come
            uint256 _max = _left - (_n - 1 - k);
            _w[k] = uint32(1 + _seed % _max);
            _left -= _w[k];
        }
        _w[_n - 1] = uint32(_left);
    }
}
