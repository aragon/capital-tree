// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget, ICheckpointedBudget} from "../interfaces/IBudget.sol";
import {IComponent} from "../interfaces/IComponent.sol";
import {BaseComponent} from "../base/BaseComponent.sol";
import {SET_SETTINGS_PERMISSION_ID, CHECKPOINT_PERMISSION_ID} from "../lib/constants.sol";

/// @title StreamBudget
/// @notice A streaming pot whose available amount only grows while the DAO can fund it. Built
///         for Dutch auctions (`OpenFillAction`), where the offered amount must rise continuously
///         and never jump.
/// @dev **Why not a plain stream.** `min(rate x elapsed, balance)` caps the amount by the balance
///      but does not stop the clock, so while the DAO is short the elapsed time keeps accruing out
///      of sight. When funds arrive, the cap lifts and the amount jumps to the whole backlog, which
///      an auction filler takes in the same block.
///
///      **How this budget avoids it.** The available amount is
///
///          min(baseAmount + rate x (now - baseTimestamp), lastSeenBalance, daoBalance, maxBudget)
///
///      - `lastSeenBalance` is the DAO balance seen at the last checkpoint or sync. A deposit
///        does not move it, so the amount cannot rise above it until a transaction picks the
///        deposit up.
///      - `sync()` (permissionless) records the DAO balance. If a cap is hiding growth, it also
///        stores the current amount as `baseAmount` and sets `baseTimestamp` to now. The amount
///        is the same just before and just after a sync, so hidden growth is discarded and the
///        stream resumes from where it froze. An uncapped curve is left untouched, so calling it
///        repeatedly loses no rounding.
///      - `writeCheckpoint()` restarts the amount from zero and records the balance left after
///        the spend. The plugin runs it once, after the whole flow (`commitActions`).
///      - The DAO balance itself caps the amount if funds leave by another path after the last
///        sync.
///      - Every setter syncs first, so a parameter change never alters what has already accrued.
///
///      **Start.** Nothing accrues until the first checkpoint. The install proposal calls
///      `writeCheckpoint()` right after applying the installation, so the stream doesn't grow while
///      the installation is voted on. Without that action the stream stays at zero, and nothing
///      flows, until a later checkpoint.
///
///      **Pause.** Pausing the plugin doesn't stop the clock. On unpause, what accrued while paused
///      is available at once, bounded by `lastSeenBalance`, the DAO balance and `maxBudget`: in an
///      auction, a filler takes it at the worst price. To resume from zero, the DAO unpauses and
///      calls `writeCheckpoint()` in the same proposal (it holds CHECKPOINT, and can grant itself PAUSE).
///
///      **Liveness.** After a deposit the amount stays frozen until someone calls `sync()`. That
///      is safe (the amount never rises) but stalls the stream, so operators should run a keeper
///      or add a `sync()` action wherever revenue enters the DAO.
///
///      **Outflows by another path.** Only a sync records a fall in the DAO balance. If the token
///      leaves the DAO by another path (another proposal or flow) and no sync follows, the curve
///      keeps growing behind the live balance. When funds come back, the amount jumps to what
///      accrued meanwhile, bounded by the stale `lastSeenBalance` and `maxBudget`: in an auction, a
///      filler takes it at the worst price, and an uncapped stream pays it at once. A sync when the
///      funds come back doesn't undo the jump. Only a sync right after the outflow prevents it, so
///      every proposal that moves the token out of the DAO must end with a `sync()` action.
///      Conversely, a sync while the balance is briefly low restarts the curve lower: never a loss
///      for the DAO, but anyone can time one to slow the stream.
///
///      One flow per instance.
contract StreamBudget is ICheckpointedBudget, BaseComponent {
    /// @notice The highest growth per epoch. Below it, `rate x elapsed` can't overflow in any realistic time.
    uint256 public constant MAX_AMOUNT_PER_EPOCH = type(uint128).max;

    /// @notice The token streamed
    IERC20 public token;

    /// @notice How much the available amount grows per epoch
    uint256 public amountPerEpoch;

    /// @notice If greater than zero, it limits the available amount at any point in time
    uint256 public maxBudget;

    /// @notice The length of an epoch in seconds
    uint256 public epochInterval;

    /// @notice The amount available at `baseTimestamp`, from which growth continues
    uint256 public baseAmount;

    /// @notice The timestamp of the last checkpoint or sync. Zero until the first checkpoint starts the stream.
    uint256 public baseTimestamp;

    /// @notice The DAO balance seen at the last checkpoint or sync. The amount never rises above it.
    uint256 public lastSeenBalance;

    /// @notice Emitted when the budget is initialized
    event BudgetSettingsUpdated(IERC20 token, uint256 amountPerEpoch, uint256 maxBudget, uint256 epochInterval);

    /// @notice Emitted when the growth per epoch is updated
    event AmountPerEpochUpdated(uint256 amountPerEpoch);

    /// @notice Emitted when the cap is updated
    event MaxBudgetUpdated(uint256 maxBudget);

    /// @notice Emitted when the epoch interval is set or updated
    event EpochIntervalUpdated(uint256 epochInterval);

    /// @notice Emitted when a checkpoint restarts the amount from zero. The first one starts the stream.
    /// @param lastSeenBalance The DAO balance recorded
    event CheckpointWritten(uint256 lastSeenBalance);

    /// @notice Emitted when the amount is carried forward and the DAO balance recorded
    /// @param baseAmount The amount available at the time of the sync
    /// @param lastSeenBalance The DAO balance seen by the sync
    /// @param rebased Whether the base amount and timestamp were rewritten
    event Synced(uint256 baseAmount, uint256 lastSeenBalance, bool indexed rebased);

    /// @notice Thrown when the token is not a contract
    error InvalidToken();

    /// @notice Thrown when the growth per epoch is above `MAX_AMOUNT_PER_EPOCH`
    error InvalidAmountPerEpoch();

    /// @notice Thrown when the given epoch interval is zero
    error InvalidEpochInterval();

    /// @notice Initializes the budget. Nothing accrues until the first checkpoint starts the stream.
    /// @param _dao The DAO holding the funds
    /// @param _settings `abi.encode(IERC20 token, uint256 amountPerEpoch, uint256 maxBudget, uint256 epochInterval)`:
    ///        the ERC20 token streamed, how much the available amount grows per epoch, the most it
    ///        can reach at any time (0 for no cap) and the epoch duration in seconds
    function initialize(IDAO _dao, address[] calldata, bytes calldata _settings) external initializer {
        (IERC20 _token, uint256 _amountPerEpoch, uint256 _maxBudget, uint256 _epochInterval) =
            abi.decode(_settings, (IERC20, uint256, uint256, uint256));
        if (address(_token).code.length == 0) revert InvalidToken();

        __DaoAuthorizableUpgradeable_init(_dao);

        token = _token;
        _setAmountPerEpoch(_amountPerEpoch);
        maxBudget = _maxBudget;
        _setEpochInterval(_epochInterval);

        emit BudgetSettingsUpdated(_token, _amountPerEpoch, _maxBudget, _epochInterval);
    }

    // IBudget

    /// @inheritdoc IBudget
    function available(address, bytes calldata) external view virtual returns (uint256) {
        return _available(_daoBalance());
    }

    /// @inheritdoc IBudget
    /// @dev One `writeCheckpoint()`, which restarts the stream from zero after the spend
    function commitActions(address, bytes calldata) external view virtual returns (Action[] memory _actions) {
        _actions = new Action[](1);
        _actions[0] = Action({to: address(this), value: 0, data: abi.encodeCall(this.writeCheckpoint, ())});
    }

    /// @inheritdoc IComponent
    /// @dev The DAO executes the commit, which writes a checkpoint
    function requiredPermissions(address _dao, address, address)
        external
        view
        virtual
        override
        returns (Permission[] memory _permissions)
    {
        _permissions = new Permission[](1);
        _permissions[0] = Permission(address(this), _dao, CHECKPOINT_PERMISSION_ID);
    }

    // Lifecycle

    /// @notice Carries the current amount forward and records the DAO balance
    /// @dev Permissionless: it never raises the current amount, it only lets the amount resume
    ///      growing after a deposit (or follow the balance down after an outflow).
    function sync() external virtual {
        _sync(false);
    }

    /// @notice Restarts the amount from zero and records the DAO balance. The first call starts the stream.
    /// @dev Executed by the DAO after the whole flow ran, so the recorded balance is what is left
    ///      after the tokens have been handed over. Also called by a bound action to restart its
    ///      auction when its demand changes, and by the install proposal to start the stream.
    function writeCheckpoint() external virtual auth(CHECKPOINT_PERMISSION_ID) {
        _writeCheckpoint();
    }

    // Manager settings. Each one syncs first, so time already elapsed keeps the old values.

    /// @notice Updates the cap on the available amount (0 for no cap)
    /// @dev Does not force a rebase; syncing still rebases when a cap hides growth
    function setMaxBudget(uint256 _maxBudget) external virtual auth(SET_SETTINGS_PERMISSION_ID) {
        _sync(false);
        maxBudget = _maxBudget;
        emit MaxBudgetUpdated(_maxBudget);
    }

    /// @notice Updates how much the available amount grows per epoch
    function setAmountPerEpoch(uint256 _amountPerEpoch) external virtual auth(SET_SETTINGS_PERMISSION_ID) {
        _sync(true);
        _setAmountPerEpoch(_amountPerEpoch);
        emit AmountPerEpochUpdated(_amountPerEpoch);
    }

    /// @notice Updates the epoch interval, which changes the growth rate
    function setEpochInterval(uint256 _epochInterval) external virtual auth(SET_SETTINGS_PERMISSION_ID) {
        _sync(true);
        _setEpochInterval(_epochInterval);
    }

    // Internal

    /// @dev The amount available for a given DAO balance
    function _available(uint256 _balance) internal view virtual returns (uint256 _amount) {
        _amount = _accrued();
        _amount = Math.min(_amount, lastSeenBalance);
        _amount = Math.min(_amount, _balance);
        if (maxBudget != 0) _amount = Math.min(_amount, maxBudget);
    }

    /// @dev The amount before any cap
    function _accrued() internal view virtual returns (uint256) {
        if (!_started()) return 0;
        return baseAmount + (amountPerEpoch * (block.timestamp - baseTimestamp)) / epochInterval;
    }

    /// @dev Records the balance and restarts the curve when a cap hides growth or `_rebase` is true.
    ///      Rate setters force a rebase; public syncs leave uncapped curves untouched to preserve rounding.
    function _sync(bool _rebase) internal virtual {
        uint256 _balance = _daoBalance();
        uint256 _amount = _available(_balance);
        bool _rebased = _started() && (_rebase || _amount < _accrued());

        if (_rebased) {
            baseAmount = _amount;
            baseTimestamp = block.timestamp;
        }
        lastSeenBalance = _balance;

        emit Synced(_amount, _balance, _rebased);
    }

    function _started() internal view returns (bool) {
        return baseTimestamp != 0;
    }

    function _writeCheckpoint() internal virtual {
        uint256 _balance = _daoBalance();
        baseAmount = 0;
        baseTimestamp = block.timestamp;
        lastSeenBalance = _balance;
        emit CheckpointWritten(_balance);
    }

    function _setAmountPerEpoch(uint256 _amountPerEpoch) internal virtual {
        if (_amountPerEpoch > MAX_AMOUNT_PER_EPOCH) revert InvalidAmountPerEpoch();
        amountPerEpoch = _amountPerEpoch;
    }

    function _setEpochInterval(uint256 _epochInterval) internal virtual {
        if (_epochInterval == 0) revert InvalidEpochInterval();
        epochInterval = _epochInterval;
        emit EpochIntervalUpdated(_epochInterval);
    }

    /// @dev The DAO's current balance of the streamed token
    function _daoBalance() internal view virtual returns (uint256) {
        return token.balanceOf(address(dao()));
    }
}
