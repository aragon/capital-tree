// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {IComponent} from "../interfaces/IComponent.sol";
import {BaseComponent} from "../base/BaseComponent.sol";
import {SET_SETTINGS_PERMISSION_ID, RECORD_CLAIM_PERMISSION_ID} from "../lib/constants.sol";

/// @title MerkleClaimBudget
/// @notice Cumulative Merkle distribution as a budget. Each leaf is (account, cumulative amount); an
///         account can claim `cumulative − claimed` at any time. A new root raises the cumulative
///         amounts for the next round.
/// @dev The flow's root receives exactly what the account is owed, so the nodes can split it, swap
///      it or take a fee before a `TransferToBeneficiaryAction` pays it out, to the address the
///      account names in that node's data.
///      One claim per trigger. Leaves use OpenZeppelin's StandardMerkleTree format:
///      keccak256(bytes.concat(keccak256(abi.encode(account, cumulative)))).
///
///      Budget data: abi.encode(address account, uint256 cumulative, bytes32[] proof).
///      Only the account itself can claim (`caller == account`), so nobody else can pick the data
///      of the nodes.
///      The claim is recorded when the budget commits, after the whole tree ran, so it rolls back
///      with the flow. One flow per instance: a second flow on the same budget could pay a claim
///      again from a node's callback before the first one records it.
///      Relayed (gasless) claims could be added later with a signature from the account over the
///      data of every node.
contract MerkleClaimBudget is IBudget, BaseComponent {
    /// @inheritdoc IBudget
    IERC20 public token;

    /// @notice The current Merkle root of (account, cumulative amount) leaves
    bytes32 public root;

    /// @notice Cumulative amount already claimed per account
    mapping(address => uint256) public claimed;

    /// @notice Emitted when the root is set or replaced
    event RootUpdated(bytes32 root);

    /// @notice Emitted when a claim is recorded
    /// @param amount What the account claimed this time, not its cumulative total
    event Claimed(address indexed account, uint256 amount);

    /// @notice Thrown when the token is not a contract
    error InvalidToken();

    /// @notice Thrown when the proof doesn't prove `(account, cumulative)` against the current root
    error InvalidProof();

    /// @notice Thrown when the caller isn't the account it claims for
    error NotTheAccount();

    /// @notice Thrown when the account already claimed its whole cumulative amount
    error NothingToClaim();

    /// @notice Initializes the budget with the root of the first round
    /// @param _dao The DAO holding the funds
    /// @param _settings `abi.encode(IERC20 token, bytes32 root)`: the ERC20 token claimed, and the
    ///        Merkle root of the first round
    function initialize(IDAO _dao, address[] calldata, bytes calldata _settings) external initializer {
        (IERC20 _token, bytes32 _root) = abi.decode(_settings, (IERC20, bytes32));
        if (address(_token).code.length == 0) revert InvalidToken();

        __DaoAuthorizableUpgradeable_init(_dao);
        token = _token;
        _setRoot(_root);
    }

    // IBudget

    /// @inheritdoc IBudget
    /// @dev What the account is owed
    function available(address _caller, bytes calldata _data) external view virtual returns (uint256 _owed) {
        (address _account, uint256 _cumulative, bytes32[] memory _proof) = _decode(_data);

        if (_caller != _account) revert NotTheAccount();
        if (!MerkleProof.verify(_proof, root, leaf(_account, _cumulative))) revert InvalidProof();
        if (_cumulative <= claimed[_account]) revert NothingToClaim();
        _owed = _cumulative - claimed[_account];
    }

    /// @inheritdoc IBudget
    /// @dev Records the claim `available` paid out
    function commitActions(address, bytes calldata _data) external view virtual returns (Action[] memory _actions) {
        (address _account, uint256 _cumulative,) = _decode(_data);

        _actions = new Action[](1);
        _actions[0] = Action({
            to: address(this), value: 0, data: abi.encodeCall(this.recordClaim, (_account, _cumulative))
        });
    }

    /// @inheritdoc IComponent
    /// @dev The DAO executes the commit, which records the claim
    function requiredPermissions(address _dao, address, address)
        external
        view
        virtual
        override
        returns (Permission[] memory _permissions)
    {
        _permissions = new Permission[](1);
        _permissions[0] = Permission(address(this), _dao, RECORD_CLAIM_PERMISSION_ID);
    }

    // Claim record

    /// @notice Records a claim. Executed by the DAO when the budget commits, so it rolls back with the flow.
    function recordClaim(address _account, uint256 _cumulative) external virtual auth(RECORD_CLAIM_PERMISSION_ID) {
        emit Claimed(_account, _cumulative - claimed[_account]);
        claimed[_account] = _cumulative;
    }

    /// @notice Replaces the root, usually with higher cumulative amounts for a new round
    /// @dev Whoever holds this can direct payouts up to the DAO's balance of the token
    function setRoot(bytes32 _root) external virtual auth(SET_SETTINGS_PERMISSION_ID) {
        _setRoot(_root);
    }

    /// @notice The leaf for `(account, cumulative)`, in OpenZeppelin's StandardMerkleTree format
    function leaf(address _account, uint256 _cumulative) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }

    function _setRoot(bytes32 _root) internal {
        root = _root;
        emit RootUpdated(_root);
    }

    /// @dev The claim in the budget data
    function _decode(bytes calldata _data)
        internal
        pure
        returns (address _account, uint256 _cumulative, bytes32[] memory _proof)
    {
        (_account, _cumulative, _proof) = abi.decode(_data, (address, uint256, bytes32[]));
    }
}
