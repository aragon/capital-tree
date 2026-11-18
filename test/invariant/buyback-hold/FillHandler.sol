// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {CapitalTreePlugin} from "../../../src/CapitalTreePlugin.sol";
import {StreamBudget} from "../../../src/budgets/StreamBudget.sol";
import {OpenFillAction} from "../../../src/actions/OpenFillAction.sol";
import {CapitalTreePluginSetup} from "../../../src/setup/CapitalTreePluginSetup.sol";
import {Buyer} from "./Buyer.sol";
import {Node} from "../../../src/lib/types.sol";
import {
    TRIGGER_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    PAUSE_PERMISSION_ID,
    SET_SETTINGS_PERMISSION_ID
} from "../../../src/lib/constants.sol";

/// @dev Alice and Bob use the same indices in buyer and balance arrays.
uint256 constant ALICE = 0;
uint256 constant BOB = 1;
uint256 constant DAO_INDEX = 2;

/// @title FillHandler
/// @notice Drives buyers, time, deposits and syncs, checking the effects of every action.
/// @dev Token names are from the DAO's perspective: the DAO sends sellToken to the buyer
/// and receives buyToken from the buyer.
/// Foundry targets independent fill and time actions, plus deposit and sync in the deposit campaign.
/// Settings and token supplies stay fixed. Expected balances and stream checkpoints are updated
/// from intended actions, independently of the production budget's state.
contract FillHandler is Test {
    CapitalTreePlugin internal plugin;
    CapitalTreePluginSetup internal setup;
    DAO internal dao;
    StreamBudget internal budget;
    OpenFillAction internal openFill;
    IERC20 internal sellToken;
    IERC20 internal buyToken;

    /// @dev The two buyer contracts, ordered as Alice (ALICE) and Bob (BOB).
    Buyer[2] internal buyers;

    /// @dev Addresses included in allowance, native-balance and passive token-balance checks.
    address[] internal checkedAddresses;

    /// @dev Raw units of sellToken accrued per epoch, copied once from the installed settings.
    uint256 internal immutable amountPerEpoch;

    /// @dev Positive maximum offer in raw units of sellToken, fixed for this test run.
    uint256 internal immutable maxBudget;

    /// @dev Epoch duration in seconds, fixed for this test run.
    uint256 internal immutable epochInterval;

    /// @dev Positive buyToken payment the buyer must send to the DAO per successful fill, in raw units.
    uint256 internal immutable demand;

    /// @dev Expected sellToken balances: Alice, Bob, DAO. Updated for successful fills and deposits.
    uint256[3] internal expectedSell;

    /// @dev Expected buyToken balances in the same order, calculated from the fixed demand.
    uint256[3] internal expectedBuy;

    /// @dev Independent accrual anchor, in raw sellToken units and seconds.
    uint256 internal expectedBaseAmount;
    uint256 internal expectedBaseTimestamp;
    /// @dev Expected DAO sellToken balance last recorded by a successful fill or sync.
    uint256 internal expectedLastSeenBalance;

    /// @notice Number of successful fills observed during the current test run.
    uint256 public successfulFills;

    /// @notice Number of rejected fill attempts whose error and rollback checks passed.
    uint256 public revertedFills;

    /// @dev Public observations captured before and after one buyer's attempt.
    struct Snapshot {
        /// @dev Actual sellToken balances, ordered as Alice, Bob, DAO.
        uint256[3] sellBalances;
        /// @dev Actual buyToken balances in the same order.
        uint256[3] buyBalances;
        /// @dev Offer reported by the stream at the observation time.
        uint256 available;
        /// @dev Stored starting amount in raw units of sellToken at baseTimestamp.
        /// Further sellToken accrual grows from this amount; a successful fill resets it to zero.
        uint256 baseAmount;
        uint256 baseTimestamp;
        /// @dev DAO sellToken balance recorded by the stream's latest checkpoint or sync.
        uint256 lastSeenBalance;
        /// @dev Settings, supplies and address observations that every fill must preserve.
        ProtectedState protectedState;
    }

    /// @dev Public configuration and supplies that stay fixed throughout this test run.
    /// permissionsHash is the setup's recorded value. Selected live permissions are checked separately.
    struct ProtectedState {
        address pluginDao;
        address pluginBudget;
        Node[] nodes;
        bool paused;
        address trustedForwarder;
        string daoURI;
        uint256 sellSupply;
        uint256 buySupply;
        address budgetDao;
        address budgetToken;
        uint256 amountPerEpoch;
        uint256 maxBudget;
        uint256 epochInterval;
        address openFillDao;
        address openFillBudget;
        address demandedToken;
        uint256 demandPerFill;
        address registry;
        bytes32 permissionsHash;
        AddressState[] accounts;
    }

    /// @dev Native balances and DAO allowances are recorded for every checked address.
    /// Token balances are populated only for addresses outside Alice, Bob and the DAO;
    /// those three holders' changing balances are recorded separately in Snapshot.
    struct AddressState {
        address account;
        uint256 nativeBalance;
        uint256 sellAllowance;
        uint256 buyAllowance;
        uint256 sellBalance;
        uint256 buyBalance;
    }

    /// @dev Structured baseline recorded after installation and funding, before any fill attempts.
    /// Stored as ABI bytes because the legacy compiler cannot copy nested Node arrays to storage.
    bytes internal initialSnapshot;

    /// @notice Records the installed contracts and starting balances for the test run.
    /// @dev Construct at the initial checkpoint's timestamp. The fixture verifies positive,
    /// fixed settings and supplies enough buyToken for the configured test depth.
    /// @param buyers_ Alice and Bob, in that order, funded with buyToken and connected to plugin_.
    /// @param checkedAddresses_ Deployed addresses to monitor for allowances and unexpected balances.
    constructor(
        CapitalTreePluginSetup setup_,
        CapitalTreePlugin plugin_,
        Buyer[2] memory buyers_,
        address[] memory checkedAddresses_
    ) {
        (setup, plugin, buyers, checkedAddresses) = (setup_, plugin_, buyers_, checkedAddresses_);
        dao = DAO(payable(address(plugin.dao())));
        budget = StreamBudget(address(plugin.budget()));
        openFill = OpenFillAction(address(plugin.nodes()[0].action));
        sellToken = budget.token();
        buyToken = openFill.demandedToken();
        // Copy the installation settings once. The tests check they were installed correctly.
        amountPerEpoch = budget.amountPerEpoch();
        maxBudget = budget.maxBudget();
        epochInterval = budget.epochInterval();
        demand = openFill.demandPerFill();
        Snapshot memory initial = _snapshot();
        initialSnapshot = abi.encode(initial);
        expectedSell = initial.sellBalances;
        expectedBuy = initial.buyBalances;
        expectedBaseTimestamp = block.timestamp; // setup has just started the stream
        expectedLastSeenBalance = expectedSell[DAO_INDEX];
        _checkLivePermissions();
    }

    /// @notice Attempts a single fill, independently of the other buyer or any time advance.
    /// @param buyerIndex Reduced modulo two to select ALICE or BOB.
    /// @param underpay Whether to pay one raw buyToken unit less than demanded.
    function fill(uint256 buyerIndex, bool underpay) external {
        _tryFill({buyerIndex: buyerIndex % buyers.length, underpay: underpay});
    }

    /// @notice Advances time independently, including repeated advances without a fill.
    /// @dev Changes only the timestamp; this does not simulate block production.
    /// @param secondsLater Bounded between zero and two epoch intervals.
    function advanceTime(uint32 secondsLater) public {
        vm.warp(block.timestamp + bound(secondsLater, 0, 2 * epochInterval));
        checkState();
    }

    /// @notice Returns some of a buyer's purchased sellToken to the DAO without syncing.
    /// @dev Uses existing tokens, preserving supply and three-holder conservation. Zero is a no-op transfer.
    /// @param buyerIndex Reduced modulo two to select ALICE or BOB.
    /// @param amount Bounded by that buyer's independently tracked sellToken balance.
    function deposit(uint256 buyerIndex, uint256 amount) external {
        uint256 buyer = buyerIndex % buyers.length;
        amount = bound(amount, 0, expectedSell[buyer]);
        uint256 availableBefore = expectedAvailable();

        buyers[buyer].deposit({amount: amount});
        expectedSell[buyer] -= amount;
        expectedSell[DAO_INDEX] += amount;

        assertEq(budget.available(address(0), ""), availableBefore, "deposit changed available sellToken");
        checkState();
    }

    /// @notice Records deposits without allowing hidden accrual to increase the current offer.
    /// @dev Predicts a new anchor only when a balance or budget limit was hiding growth.
    /// An uncapped sync preserves the original anchor and its fractional accrual.
    function sync() external {
        uint256 availableBefore = expectedAvailable();
        bool clipped = availableBefore < _expectedAccrued();

        budget.sync();
        if (clipped) {
            expectedBaseAmount = availableBefore;
            expectedBaseTimestamp = block.timestamp;
        }
        expectedLastSeenBalance = expectedSell[DAO_INDEX];

        assertEq(budget.available(address(0), ""), availableBefore, "sync changed available sellToken");
        checkState();
    }

    /// @notice Attempts two fills without changing the timestamp or block number.
    /// @dev Each attempt is checked separately, so a rejected second fill must preserve the first.
    /// @param firstBuyer Reduced modulo two: ALICE goes first for even values, BOB for odd values.
    /// @param firstUnderpays Whether the first buyer pays one raw unit of buyToken too little.
    /// @param secondUnderpays Whether the other buyer pays one raw unit of buyToken too little.
    function sameBlock(uint256 firstBuyer, bool firstUnderpays, bool secondUnderpays) external {
        uint256 first = firstBuyer % 2;
        _tryFill(first, firstUnderpays);
        _tryFill(first == ALICE ? BOB : ALICE, secondUnderpays);
    }

    /// @notice Attempts one fill, advances time, then lets the other buyer try.
    /// @dev Changes only the timestamp; this test does not simulate block production.
    /// @param firstBuyer Reduced modulo two: ALICE goes first for even values, BOB for odd values.
    /// @param secondsLater Mapped by bound into the inclusive range from zero to two epochs.
    /// @param firstUnderpays Whether the first buyer pays one raw unit of buyToken too little.
    /// @param secondUnderpays Whether the other buyer pays one raw unit of buyToken too little.
    function afterDelay(uint256 firstBuyer, uint32 secondsLater, bool firstUnderpays, bool secondUnderpays) external {
        uint256 first = firstBuyer % 2;
        _tryFill(first, firstUnderpays);
        advanceTime({secondsLater: secondsLater});
        _tryFill(first == ALICE ? BOB : ALICE, secondUnderpays);
    }

    /// @notice Snapshots one fill attempt and verifies either settlement or complete observed rollback.
    /// @dev A funded, fully paid fill must succeed. Empty offers and underpayments must produce
    /// their specific errors. A rejected fill must preserve balances and the accrual anchor.
    /// @param buyerIndex Index of the buyer attempting the fill; must be ALICE or BOB.
    /// @param underpay Whether this buyer deliberately pays one raw unit of buyToken too little.
    function _tryFill(uint256 buyerIndex, bool underpay) internal {
        Snapshot memory before_ = _snapshot();
        uint256 offer = expectedAvailable();
        assertEq(before_.available, offer, "stream disagrees with expected offer");

        (bool succeeded, bytes memory reason, Vm.Log[] memory logs) = _executeFill(buyerIndex, underpay);
        Snapshot memory after_ = _snapshot();
        assertEq(succeeded, offer > 0 && !underpay, "unexpected fill outcome");

        if (succeeded) {
            _checkSuccessfulFill(buyerIndex, offer, after_, logs);
        } else {
            _checkRevertedFill(offer, reason, before_, after_);
        }
        checkState();
    }

    /// @dev Attempts the buyer call and captures its outcome and logs. Assertions stay in the caller.
    function _executeFill(uint256 buyerIndex, bool underpay)
        internal
        returns (bool succeeded, bytes memory reason, Vm.Log[] memory logs)
    {
        vm.recordLogs();
        try buyers[buyerIndex].buy(underpay) {
            succeeded = true;
        } catch (bytes memory why) {
            reason = why;
        }
        logs = vm.getRecordedLogs();
    }

    /// @dev Records the expected sellToken/buyToken exchange, then checks the stream reset and events.
    /// Increment the successful-fill count before checking events so it matches the emitted nonce.
    function _checkSuccessfulFill(uint256 buyerIndex, uint256 offer, Snapshot memory after_, Vm.Log[] memory logs)
        internal
    {
        expectedSell[DAO_INDEX] -= offer;
        expectedSell[buyerIndex] += offer;
        expectedBuy[DAO_INDEX] += demand;
        expectedBuy[buyerIndex] -= demand;
        expectedBaseAmount = 0;
        expectedBaseTimestamp = block.timestamp;
        expectedLastSeenBalance = expectedSell[DAO_INDEX];
        ++successfulFills;

        assertEq(after_.available, 0, "fill must restart the stream");
        assertEq(after_.baseAmount, 0, "checkpoint amount");
        assertEq(after_.baseTimestamp, block.timestamp, "checkpoint time");
        assertEq(after_.lastSeenBalance, expectedSell[DAO_INDEX], "checkpoint must use remaining balance");
        _checkExecutionEvents(logs, buyerIndex);
    }

    /// @dev Checks the exact error and unchanged snapshot before counting a rejected attempt.
    /// An empty sellToken offer takes precedence over an insufficient buyToken payment.
    function _checkRevertedFill(uint256 offer, bytes memory reason, Snapshot memory before_, Snapshot memory after_)
        internal
    {
        bytes memory expectedError;
        if (offer == 0) {
            expectedError = abi.encodeWithSelector(CapitalTreePlugin.EmptyInput.selector, 0);
        } else {
            uint256 requiredBuyBalance = before_.buyBalances[DAO_INDEX] + demand;
            expectedError = abi.encodeWithSelector(
                OpenFillAction.DemandNotMet.selector, requiredBuyBalance, requiredBuyBalance - 1
            );
        }
        assertEq(reason, expectedError, "reverted for the wrong reason");
        _checkRollback(before_, after_);
        ++revertedFills;
    }

    /// @notice Calculates the offer expected at the current timestamp.
    /// @dev Uses elapsed time and our expected remaining DAO sellToken balance, not the stream's current
    /// internal state. Deposits change balances; only fills and clipped syncs move the accrual anchor.
    /// @return amount Accrued raw units of sellToken, rounded down and limited by maxBudget
    /// and the DAO's remaining sellToken balance.
    function expectedAvailable() public view returns (uint256 amount) {
        amount = _expectedAccrued();
        if (amount > expectedLastSeenBalance) amount = expectedLastSeenBalance;
        if (maxBudget != 0 && amount > maxBudget) amount = maxBudget;
        if (amount > expectedSell[DAO_INDEX]) amount = expectedSell[DAO_INDEX];
    }

    /// @dev Uncapped accrual from the model's own anchor, without reading the production budget.
    function _expectedAccrued() internal view returns (uint256) {
        return expectedBaseAmount + amountPerEpoch * (block.timestamp - expectedBaseTimestamp) / epochInterval;
    }

    /// @notice Checks actual balances, stream availability and protected observations against expectations.
    /// @dev Also checks that the DAO and the two buyers together hold the full supply of each token.
    /// Called after every action and by the invariant entry point after each handler call.
    function checkState() public view {
        Snapshot memory current = _snapshot();
        Snapshot memory initial = abi.decode(initialSnapshot, (Snapshot));
        assertEq(current.available, expectedAvailable(), "stream growth/reset");
        assertEq(current.baseAmount, expectedBaseAmount, "stream baseAmount");
        assertEq(current.baseTimestamp, expectedBaseTimestamp, "stream baseTimestamp");
        assertEq(current.lastSeenBalance, expectedLastSeenBalance, "stream lastSeenBalance");
        _checkLivePermissions();
        _checkProtectedState(current.protectedState, initial.protectedState);
        _checkHolderBalances(current, expectedSell, expectedBuy);
        // This check uses actual balances, independently of our running accounting totals.
        assertEq(
            current.sellBalances[ALICE] + current.sellBalances[BOB] + current.sellBalances[DAO_INDEX],
            sellToken.totalSupply()
        );
        assertEq(
            current.buyBalances[ALICE] + current.buyBalances[BOB] + current.buyBalances[DAO_INDEX],
            buyToken.totalSupply()
        );
    }

    /// @dev Checks effective permissions in the live DAO, including wildcard grants.
    /// Covers required execute/checkpoint grants and each buyer's trigger, root, execute,
    /// configure, checkpoint, pause and component-settings permissions; not every permission ID.
    function _checkLivePermissions() internal view {
        _assertPermission({
            where: address(dao),
            who: address(plugin),
            permissionId: dao.EXECUTE_PERMISSION_ID(),
            expected: true,
            description: "plugin execute permission changed"
        });
        _assertPermission({
            where: address(budget),
            who: address(dao),
            permissionId: CHECKPOINT_PERMISSION_ID,
            expected: true,
            description: "DAO checkpoint permission changed"
        });
        _assertPermission({
            where: address(budget),
            who: address(openFill),
            permissionId: CHECKPOINT_PERMISSION_ID,
            expected: true,
            description: "OpenFill checkpoint permission changed"
        });
        string[2] memory labels = ["Alice", "Bob"];
        for (uint256 i; i < buyers.length; ++i) {
            address buyer = address(buyers[i]);
            _assertPermission({
                where: address(plugin),
                who: buyer,
                permissionId: TRIGGER_PERMISSION_ID,
                expected: true,
                description: string.concat(labels[i], " trigger permission changed")
            });
            _assertPermission({
                where: address(dao),
                who: buyer,
                permissionId: dao.ROOT_PERMISSION_ID(),
                expected: false,
                description: string.concat(labels[i], " root permission changed")
            });
            _assertPermission({
                where: address(dao),
                who: buyer,
                permissionId: dao.EXECUTE_PERMISSION_ID(),
                expected: false,
                description: string.concat(labels[i], " execute permission changed")
            });
            _assertPermission({
                where: address(plugin),
                who: buyer,
                permissionId: CONFIGURE_PERMISSION_ID,
                expected: false,
                description: string.concat(labels[i], " configure permission changed")
            });
            _assertPermission({
                where: address(budget),
                who: buyer,
                permissionId: CHECKPOINT_PERMISSION_ID,
                expected: false,
                description: string.concat(labels[i], " checkpoint permission changed")
            });
            _assertPermission({
                where: address(plugin),
                who: buyer,
                permissionId: PAUSE_PERMISSION_ID,
                expected: false,
                description: string.concat(labels[i], " pause permission changed")
            });
            _assertPermission({
                where: address(budget),
                who: buyer,
                permissionId: SET_SETTINGS_PERMISSION_ID,
                expected: false,
                description: string.concat(labels[i], " budget settings permission changed")
            });
            _assertPermission({
                where: address(openFill),
                who: buyer,
                permissionId: SET_SETTINGS_PERMISSION_ID,
                expected: false,
                description: string.concat(labels[i], " fill settings permission changed")
            });
        }
    }

    /// @dev Checks this fixture's unconditional grants with empty authorization data.
    /// Conditional permissions that depend on call data are outside this campaign.
    function _assertPermission(
        address where,
        address who,
        bytes32 permissionId,
        bool expected,
        string memory description
    ) internal view {
        assertEq(
            dao.hasPermission({_where: where, _who: who, _permissionId: permissionId, _data: ""}), expected, description
        );
    }

    /// @notice Reads balances, stream state and the public observations that a fill must preserve.
    /// @dev protectedState covers the configuration reads below, token supplies, native balances
    /// and DAO allowances at checkedAddresses, plus token balances outside the DAO and buyers.
    /// The setup permission hash is observed here; checkState also verifies selected live DAO permissions.
    /// @return s Observed state used to compare one attempt or check against the initial baseline.
    function _snapshot() internal view returns (Snapshot memory s) {
        address[3] memory holders = [address(buyers[ALICE]), address(buyers[BOB]), address(dao)];
        for (uint256 i; i < 3; ++i) {
            s.sellBalances[i] = sellToken.balanceOf(holders[i]);
            s.buyBalances[i] = buyToken.balanceOf(holders[i]);
        }
        s.available = budget.available(address(0), "");
        s.baseAmount = budget.baseAmount();
        s.baseTimestamp = budget.baseTimestamp();
        s.lastSeenBalance = budget.lastSeenBalance();
        s.protectedState = _snapshotProtectedState();
    }

    /// @dev Reads each protected field explicitly so failures can name the changed setting.
    function _snapshotProtectedState() internal view returns (ProtectedState memory s) {
        s.pluginDao = address(plugin.dao());
        s.pluginBudget = address(plugin.budget());
        s.nodes = plugin.nodes();
        s.paused = plugin.paused();
        s.trustedForwarder = dao.getTrustedForwarder();
        s.daoURI = dao.daoURI();
        s.sellSupply = sellToken.totalSupply();
        s.buySupply = buyToken.totalSupply();
        s.budgetDao = address(budget.dao());
        s.budgetToken = address(budget.token());
        s.amountPerEpoch = budget.amountPerEpoch();
        s.maxBudget = budget.maxBudget();
        s.epochInterval = budget.epochInterval();
        s.openFillDao = address(openFill.dao());
        s.openFillBudget = address(openFill.budget());
        s.demandedToken = address(openFill.demandedToken());
        s.demandPerFill = openFill.demandPerFill();
        s.registry = address(setup.registry());
        s.permissionsHash = setup.permissionsHash(address(plugin));
        s.accounts = _snapshotAccounts();
    }

    /// @dev Captures allowances and balances in checkedAddresses order.
    function _snapshotAccounts() internal view returns (AddressState[] memory accounts) {
        accounts = new AddressState[](checkedAddresses.length);
        for (uint256 i; i < checkedAddresses.length; ++i) {
            address who = checkedAddresses[i];
            accounts[i].account = who;
            accounts[i].nativeBalance = who.balance;
            accounts[i].sellAllowance = sellToken.allowance(address(dao), who);
            accounts[i].buyAllowance = buyToken.allowance(address(dao), who);
            if (who != address(buyers[ALICE]) && who != address(buyers[BOB]) && who != address(dao)) {
                accounts[i].sellBalance = sellToken.balanceOf(who);
                accounts[i].buyBalance = buyToken.balanceOf(who);
            }
        }
    }

    /// @dev A rejected attempt must preserve every recorded field, including the stream checkpoint.
    function _checkRollback(Snapshot memory before_, Snapshot memory after_) internal pure {
        _checkHolderBalances(after_, before_.sellBalances, before_.buyBalances);
        assertEq(after_.available, before_.available, "revert changed available sellToken");
        assertEq(after_.baseAmount, before_.baseAmount, "revert changed baseAmount");
        assertEq(after_.baseTimestamp, before_.baseTimestamp, "revert changed baseTimestamp");
        assertEq(after_.lastSeenBalance, before_.lastSeenBalance, "revert changed lastSeenBalance");
        _checkProtectedState(after_.protectedState, before_.protectedState);
    }

    /// @dev Uses the same Alice, Bob, DAO ordering for expected and observed balances.
    function _checkHolderBalances(Snapshot memory actual, uint256[3] memory sellExpected, uint256[3] memory buyExpected)
        internal
        pure
    {
        assertEq(actual.sellBalances[ALICE], sellExpected[ALICE], "Alice sellToken balance changed");
        assertEq(actual.sellBalances[BOB], sellExpected[BOB], "Bob sellToken balance changed");
        assertEq(actual.sellBalances[DAO_INDEX], sellExpected[DAO_INDEX], "DAO sellToken balance changed");
        assertEq(actual.buyBalances[ALICE], buyExpected[ALICE], "Alice buyToken balance changed");
        assertEq(actual.buyBalances[BOB], buyExpected[BOB], "Bob buyToken balance changed");
        assertEq(actual.buyBalances[DAO_INDEX], buyExpected[DAO_INDEX], "DAO buyToken balance changed");
    }

    /// @dev Compares fixed settings and supplies, then checks every node and monitored address.
    function _checkProtectedState(ProtectedState memory actual, ProtectedState memory expected) internal pure {
        assertEq(actual.pluginDao, expected.pluginDao, "plugin.dao changed");
        assertEq(actual.pluginBudget, expected.pluginBudget, "plugin.budget changed");
        _checkNodes(actual.nodes, expected.nodes);
        assertEq(actual.paused, expected.paused, "plugin.paused changed");
        assertEq(actual.trustedForwarder, expected.trustedForwarder, "DAO trustedForwarder changed");
        assertEq(actual.daoURI, expected.daoURI, "DAO URI changed");
        assertEq(actual.sellSupply, expected.sellSupply, "sellToken totalSupply changed");
        assertEq(actual.buySupply, expected.buySupply, "buyToken totalSupply changed");
        assertEq(actual.budgetDao, expected.budgetDao, "budget.dao changed");
        assertEq(actual.budgetToken, expected.budgetToken, "budget.token changed");
        assertEq(actual.amountPerEpoch, expected.amountPerEpoch, "budget.amountPerEpoch changed");
        assertEq(actual.maxBudget, expected.maxBudget, "budget.maxBudget changed");
        assertEq(actual.epochInterval, expected.epochInterval, "budget.epochInterval changed");
        assertEq(actual.openFillDao, expected.openFillDao, "openFill.dao changed");
        assertEq(actual.openFillBudget, expected.openFillBudget, "openFill.budget changed");
        assertEq(actual.demandedToken, expected.demandedToken, "openFill.demandedToken changed");
        assertEq(actual.demandPerFill, expected.demandPerFill, "openFill.demandPerFill changed");
        assertEq(actual.registry, expected.registry, "setup.registry changed");
        assertEq(actual.permissionsHash, expected.permissionsHash, "setup.permissionsHash changed");
        _checkAccounts(actual.accounts, expected.accounts);
    }

    /// @dev Includes every Node field and each child index, with the node index in failure messages.
    function _checkNodes(Node[] memory actual, Node[] memory expected) internal pure {
        assertEq(actual.length, expected.length, "node count changed");
        for (uint256 i; i < actual.length; ++i) {
            string memory label = string.concat("node ", vm.toString(i));
            assertEq(address(actual[i].action), address(expected[i].action), string.concat(label, " action changed"));
            assertEq(
                address(actual[i].splitter), address(expected[i].splitter), string.concat(label, " splitter changed")
            );
            assertEq(actual[i].skipWhenEmpty, expected[i].skipWhenEmpty, string.concat(label, " skipWhenEmpty changed"));
            assertEq(
                actual[i].forwardSurplus, expected[i].forwardSurplus, string.concat(label, " forwardSurplus changed")
            );
            assertEq(
                actual[i].children.length, expected[i].children.length, string.concat(label, " child count changed")
            );
            for (uint256 j; j < actual[i].children.length; ++j) {
                assertEq(
                    actual[i].children[j],
                    expected[i].children[j],
                    string.concat(label, " child ", vm.toString(j), " changed")
                );
            }
        }
    }

    /// @dev Reports the monitored address and the allowance or balance that changed.
    function _checkAccounts(AddressState[] memory actual, AddressState[] memory expected) internal pure {
        assertEq(actual.length, expected.length, "checked address count changed");
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i].account, expected[i].account, "checked address changed");
            string memory label = string.concat("address ", vm.toString(actual[i].account));
            assertEq(
                actual[i].nativeBalance, expected[i].nativeBalance, string.concat(label, " native balance changed")
            );
            assertEq(
                actual[i].sellAllowance, expected[i].sellAllowance, string.concat(label, " sellToken allowance changed")
            );
            assertEq(
                actual[i].buyAllowance, expected[i].buyAllowance, string.concat(label, " buyToken allowance changed")
            );
            assertEq(actual[i].sellBalance, expected[i].sellBalance, string.concat(label, " sellToken balance changed"));
            assertEq(actual[i].buyBalance, expected[i].buyBalance, string.concat(label, " buyToken balance changed"));
        }
    }

    /// @notice Requires one flow event and one budget commit event for a successful fill.
    /// @dev Called after successfulFills is incremented. The emitted nonce must match that count,
    /// which also detects nonce increments from earlier rejected attempts once another fill succeeds.
    /// @param logs Logs recorded while the buyer attempted its fill.
    /// @param buyerIndex Index of the buyer that must appear as the flow's caller.
    function _checkExecutionEvents(Vm.Log[] memory logs, uint256 buyerIndex) internal view {
        uint256 executions;
        uint256 commits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(plugin)) continue;
            if (logs[i].topics[0] == keccak256("FlowExecuted(address,uint64,(address,uint256))")) {
                ++executions;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(buyers[buyerIndex]));
                assertEq(uint256(logs[i].topics[2]), successfulFills, "unexpected flow nonce");
            }
            if (logs[i].topics[0] == keccak256("BudgetCommitted(bytes32)")) ++commits;
        }
        assertEq(executions, 1, "one flow per fill");
        assertEq(commits, 1, "one budget commit per fill");
    }
}
