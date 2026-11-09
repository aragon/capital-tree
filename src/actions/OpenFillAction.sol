// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget, ICheckpointedBudget} from "../interfaces/IBudget.sol";
import {IFiller} from "../interfaces/IFiller.sol";
import {Input, Movement} from "../lib/types.sol";
import {MANAGER_PERMISSION_ID} from "../lib/constants.sol";

/// @title OpenFillAction
/// @notice Take-it-or-leave-it swap priced as a Dutch auction. It offers its whole input; the DAO
///         demands a flat `demandPerFill` back; any filler can take it.
/// @dev The price obtained is `demandPerFill / offered`, so it worsens as the offer grows. The
///      action has no cap of its own: the recipe sets the worst price through the cap of the
///      stream that feeds it (`FundedStreamBudget.maxBudget`) and the nodes above it. The worst
///      price is `demandPerFill` over the most the node can receive.
///      Changing `demandPerFill` restarts the budget, so a filler cannot take an offer that
///      accumulated under the old demand at the new one.
///      `demandPerFill` is a minimum. On a node marked `forwardSurplus`, the children get everything
///      the filler sent; otherwise they get `demandPerFill` and the rest stays in the DAO.
contract OpenFillAction is INodeAction, DaoAuthorizableUpgradeable {
    /// @inheritdoc INodeAction
    /// @dev The budget restarted when `demandPerFill` changes
    IBudget public budget;

    /// @notice The token the DAO must receive back
    IERC20 public demandedToken;

    /// @notice How much of the demanded token must come back per fill
    uint256 public demandPerFill;

    /// @notice Emitted when the demand is set or updated
    event DemandPerFillUpdated(uint256 demandPerFill);

    /// @notice Thrown when the budget is address(0)
    error NoBudget();

    /// @notice Thrown when the demanded token is not a contract
    error InvalidToken();

    /// @notice Thrown when the demanded token is the budget's token
    error SameToken();

    /// @notice Thrown when the demand is zero (it would give the offered token away)
    error ZeroDemand();

    /// @notice Thrown when the DAO holds less of the demanded token than the fill requires
    error DemandNotMet(uint256 required, uint256 actual);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _dao The DAO executing the fills
    /// @param _budget The flow's budget; this action restarts it when the demand changes
    /// @param _demandedToken The ERC20 token the DAO must receive back
    /// @param _demandPerFill How much of the demanded token must come back per fill
    function initialize(IDAO _dao, ICheckpointedBudget _budget, IERC20 _demandedToken, uint256 _demandPerFill)
        external
        initializer
    {
        if (address(_budget) == address(0)) revert NoBudget();
        if (address(_demandedToken).code.length == 0) revert InvalidToken();
        if (_demandedToken == _budget.token()) revert SameToken();

        __DaoAuthorizableUpgradeable_init(_dao);

        budget = _budget;
        demandedToken = _demandedToken;
        _setDemandPerFill(_demandPerFill);
    }

    // INodeAction

    /// @inheritdoc INodeAction
    /// @dev Nothing blocks a fill. Snapshot: the DAO's balance of the demanded token before it.
    function preconditions(address, bytes calldata, Movement calldata _movement)
        external
        view
        virtual
        returns (bytes memory)
    {
        return abi.encode(_movement.outToken.balanceOf(address(dao())));
    }

    /// @inheritdoc INodeAction
    /// @dev ERC20 offer of the whole input: approve it to the caller, call it back, clear the approval.
    function build(address _caller, bytes calldata _data, Input calldata _input)
        external
        view
        virtual
        returns (Movement memory _movement, Action[] memory _actions)
    {
        _movement = Movement({
            inToken: _input.token,
            inAmount: _input.amount,
            outToken: demandedToken,
            outAmount: demandPerFill,
            beneficiary: _input.beneficiary
        });

        bytes memory _callback =
            abi.encodeCall(IFiller.fillOffer, (_input.token, _input.amount, demandedToken, demandPerFill, _data));

        address _in = address(_input.token);
        _actions = new Action[](3);
        _actions[0] = Action({to: _in, value: 0, data: abi.encodeCall(IERC20.approve, (_caller, _input.amount))});
        _actions[1] = Action({to: _caller, value: 0, data: _callback});
        _actions[2] = Action({to: _in, value: 0, data: abi.encodeCall(IERC20.approve, (_caller, 0))});
    }

    /// @inheritdoc INodeAction
    /// @dev Reverts the whole trigger unless the DAO received at least `outAmount`
    function postconditions(address, Movement calldata _movement, bytes calldata _snapshot) external view virtual {
        uint256 _minBalance = abi.decode(_snapshot, (uint256)) + _movement.outAmount;
        uint256 _balance = _movement.outToken.balanceOf(address(dao()));
        if (_balance < _minBalance) revert DemandNotMet(_minBalance, _balance);
    }

    // Manager settings

    /// @notice Updates how much must come back per fill, and restarts the auction
    function setDemandPerFill(uint256 _demandPerFill) external virtual auth(MANAGER_PERMISSION_ID) {
        _setDemandPerFill(_demandPerFill);
        _restartAuction();
    }

    // Internal

    /// @dev Bound at init to an ICheckpointedBudget, so the cast is safe
    function _restartAuction() internal virtual {
        ICheckpointedBudget(address(budget)).writeCheckpoint();
    }

    function _setDemandPerFill(uint256 _demandPerFill) internal virtual {
        if (_demandPerFill == 0) revert ZeroDemand();
        demandPerFill = _demandPerFill;
        emit DemandPerFillUpdated(_demandPerFill);
    }
}
