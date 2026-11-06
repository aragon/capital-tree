// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../../src/budgets/FundedStreamBudget.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {KeepAction} from "../../src/actions/KeepAction.sol";
import {GenericFillSolver} from "../../src/solvers/GenericSwapSolver.sol";
import {Node} from "../../src/lib/types.sol";
import {
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID
} from "../../src/lib/constants.sol";

/// @dev Shared in-memory fixture: funded stream -> OpenFill -> Keep. No broadcast.
abstract contract DeployFlow is Script {
    address internal constant ADMIN = address(0xA11CE);
    uint256 public constant EPOCH = 1 hours;

    struct Deployment {
        DAO dao;
        CapitalPipelinePlugin plugin;
        FundedStreamBudget budget;
        OpenFillAction action;
        GenericFillSolver solver;
        IERC20 sell;
        IERC20 buy;
    }

    /// @dev Fund the DAO and sync the budget afterwards, then let one epoch accrue.
    function _deploy(IERC20 sell, IERC20 buy, uint256 amount, uint256 demand, address operator)
        internal
        returns (Deployment memory d)
    {
        vm.startPrank(ADMIN);
        d.dao = DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(new DAO()), abi.encodeCall(DAO.initialize, ("", ADMIN, address(0), ""))
                ))
        );
        d.sell = sell;
        d.buy = buy;
        d.budget = FundedStreamBudget(
            ProxyLib.deployMinimalProxy(
                address(new FundedStreamBudget()),
                abi.encodeCall(FundedStreamBudget.initialize, (d.dao, sell, amount, amount, EPOCH))
            )
        );
        d.action = OpenFillAction(
            ProxyLib.deployMinimalProxy(
                address(new OpenFillAction()),
                abi.encodeCall(OpenFillAction.initialize, (d.dao, d.budget, buy, demand, demand * 1e18 / amount))
            )
        );
        KeepAction keep = KeepAction(
            ProxyLib.deployMinimalProxy(address(new KeepAction()), abi.encodeCall(KeepAction.initialize, (d.dao)))
        );
        Node[] memory nodes = new Node[](2);
        nodes[0].action = d.action;
        nodes[0].children = new uint32[](1);
        nodes[0].children[0] = 1;
        nodes[1].action = keep;
        d.plugin = CapitalPipelinePlugin(
            ProxyLib.deployMinimalProxy(
                address(new CapitalPipelinePlugin()),
                abi.encodeCall(CapitalPipelinePlugin.initialize, (d.dao, d.budget, nodes))
            )
        );
        d.dao.grant(address(d.dao), address(d.plugin), d.dao.EXECUTE_PERMISSION_ID());
        d.dao.grant(address(d.plugin), address(d.dao), CONFIGURE_PERMISSION_ID);
        d.dao.grant(address(d.plugin), ADMIN, MANAGER_PERMISSION_ID);
        d.dao.grant(address(d.budget), ADMIN, MANAGER_PERMISSION_ID);
        d.dao.grant(address(d.action), ADMIN, MANAGER_PERMISSION_ID);
        d.dao.grant(address(d.budget), address(d.dao), CHECKPOINT_PERMISSION_ID);
        d.dao.grant(address(d.budget), address(d.action), CHECKPOINT_PERMISSION_ID);
        d.solver = new GenericFillSolver(operator, d.plugin);
        d.dao.grant(address(d.plugin), address(d.solver), TRIGGER_PERMISSION_ID);
        vm.stopPrank();
    }
}
