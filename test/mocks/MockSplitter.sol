// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IComponent} from "../../src/interfaces/IComponent.sol";
import {ISplitter} from "../../src/interfaces/ISplitter.sol";
import {Asset} from "../../src/lib/types.sol";

/// @dev Gives the first of two children up to `cap` and the second the rest
contract CapSplitter is ISplitter, IComponent, DaoAuthorizableUpgradeable {
    uint256 public cap;

    /// @dev Settings: abi.encode(uint256 cap)
    function initialize(IDAO _dao, address[] calldata, bytes calldata _settings) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
        cap = abi.decode(_settings, (uint256));
    }

    function requiredPermissions(address, address, address) external pure returns (Permission[] memory) {}

    function split(address, Asset calldata _output, uint256) external view returns (uint256[] memory _amounts) {
        _amounts = new uint256[](2);
        _amounts[0] = _output.amount < cap ? _output.amount : cap;
        _amounts[1] = _output.amount - _amounts[0];
    }

    function childCount() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Returns the amounts it was given, whatever the output
contract FixedSplitter is ISplitter, DaoAuthorizableUpgradeable {
    uint256[] internal _amounts;

    function initialize(IDAO _dao, uint256[] calldata _fixed) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
        _amounts = _fixed;
    }

    function split(address, Asset calldata, uint256) external view returns (uint256[] memory) {
        return _amounts;
    }

    /// @dev Any: lets a wrong number of amounts reach the trigger
    function childCount() external pure returns (uint256) {
        return 0;
    }
}
