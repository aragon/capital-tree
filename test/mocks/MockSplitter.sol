// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Record} from "../../src/lib/types.sol";

/// @dev Gives the first of two children up to `cap` and the second the rest
contract CapSplitter is ISplitter, DaoAuthorizableUpgradeable {
    uint256 public cap;

    function initialize(IDAO _dao, uint256 _cap) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
        cap = _cap;
    }

    function split(address, Record calldata _parent, uint256) external view returns (uint256[] memory _amounts) {
        _amounts = new uint256[](2);
        _amounts[0] = _parent.forwarded < cap ? _parent.forwarded : cap;
        _amounts[1] = _parent.forwarded - _amounts[0];
    }
}

/// @dev Returns the amounts it was given, whatever the output
contract FixedSplitter is ISplitter, DaoAuthorizableUpgradeable {
    uint256[] internal _amounts;

    function initialize(IDAO _dao, uint256[] calldata _fixed) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
        _amounts = _fixed;
    }

    function split(address, Record calldata, uint256) external view returns (uint256[] memory) {
        return _amounts;
    }
}

/// @dev Gives the first of two children what the parent expected and the second the surplus
contract SurplusSplitter is ISplitter, DaoAuthorizableUpgradeable {
    function initialize(IDAO _dao) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
    }

    function split(address, Record calldata _parent, uint256) external pure returns (uint256[] memory _amounts) {
        uint256 _expected = _parent.expected.outAmount;
        _amounts = new uint256[](2);
        _amounts[0] = _parent.forwarded < _expected ? _parent.forwarded : _expected;
        _amounts[1] = _parent.forwarded - _amounts[0];
    }
}
