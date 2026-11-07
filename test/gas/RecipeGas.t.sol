// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IExecutor, Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../../src/budgets/FundedStreamBudget.sol";
import {MerkleClaimBudget} from "../../src/budgets/MerkleClaimBudget.sol";
import {TransferAction} from "../../src/actions/TransferAction.sol";
import {INodeAction} from "../../src/interfaces/INodeAction.sol";
import {IFiller} from "../../src/interfaces/IFiller.sol";
import {Node} from "../../src/lib/types.sol";
import {RATIO_BASE} from "../../src/lib/constants.sol";
import {Fixture} from "../helpers/Fixture.sol";

interface ITrigger {
    function trigger(bytes calldata budgetData, bytes[] calldata data) external;
}

/// @notice Triggers a flow and fills its offer, with no bookkeeping of its own
contract LeanFiller is IFiller {
    function fill(ITrigger _target) external {
        _target.trigger("", new bytes[](0));
    }

    function fillOffer(IERC20 _offered, uint256 _amount, IERC20 _demanded, uint256 _demandedAmount, bytes calldata)
        external
    {
        _offered.transferFrom(msg.sender, address(this), _amount);
        _demanded.transfer(msg.sender, _demandedAmount);
    }
}

function _transfer(IERC20 _token, address _to, uint256 _amount) pure returns (Action memory) {
    return Action(address(_token), 0, abi.encodeCall(IERC20.transfer, (_to, _amount)));
}

// Minimal: one fixed flow written by hand. Same budget, one dao.execute, only the checks it can't skip.

/// @notice Stream → OpenFill → burn, minus a fee. One balance check: the DAO ends with at least the
///         demanded token it started with, so the filler paid for the burn and the fee.
contract MinimalSwap is ITrigger {
    IDAO public dao;
    FundedStreamBudget public budget;
    IERC20 public demanded;
    uint256 public demandPerFill;
    address public fee;
    uint32 public feeWeight;

    error DemandNotMet();

    constructor(
        IDAO _dao,
        FundedStreamBudget _budget,
        IERC20 _demanded,
        uint256 _demandPerFill,
        address _fee,
        uint32 _feeWeight
    ) {
        (dao, budget, demanded, demandPerFill, fee, feeWeight) =
        (_dao, _budget, _demanded, _demandPerFill, _fee, _feeWeight);
    }

    function trigger(bytes calldata, bytes[] calldata) external {
        IERC20 _offered = budget.token();
        (uint256 _amount,) = budget.available(msg.sender, "");
        uint256 _demand = demandPerFill;
        uint256 _fee = (_demand * feeWeight) / RATIO_BASE;
        uint256 _before = demanded.balanceOf(address(dao));

        Action[] memory _actions = new Action[](_fee == 0 ? 5 : 6);
        _actions[0] = Action(address(_offered), 0, abi.encodeCall(IERC20.approve, (msg.sender, _amount)));
        _actions[1] =
            Action(msg.sender, 0, abi.encodeCall(IFiller.fillOffer, (_offered, _amount, demanded, _demand, bytes(""))));
        _actions[2] = Action(address(_offered), 0, abi.encodeCall(IERC20.approve, (msg.sender, 0)));
        _actions[3] = Action(address(demanded), 0, abi.encodeCall(ERC20Burnable.burn, (_demand - _fee)));
        _actions[4] = Action(address(budget), 0, abi.encodeCall(FundedStreamBudget.writeCheckpoint, ()));
        if (_fee != 0) _actions[5] = _transfer(demanded, fee, _fee);
        IExecutor(address(dao)).execute(bytes32(0), _actions, 0);

        if (demanded.balanceOf(address(dao)) < _before) revert DemandNotMet();
    }
}

/// @notice Merkle claim → pay the beneficiary
contract MinimalClaim is ITrigger {
    IDAO public dao;
    MerkleClaimBudget public budget;

    constructor(IDAO _dao, MerkleClaimBudget _budget) {
        (dao, budget) = (_dao, _budget);
    }

    function trigger(bytes calldata _budgetData, bytes[] calldata) external {
        (uint256 _amount, address _beneficiary) = budget.available(msg.sender, _budgetData);
        (address _account, uint256 _cumulative,,) = abi.decode(_budgetData, (address, uint256, bytes32[], address));

        Action[] memory _actions = new Action[](2);
        _actions[0] = _transfer(budget.token(), _beneficiary, _amount);
        _actions[1] = Action(
            address(budget), 0, abi.encodeCall(MerkleClaimBudget.recordClaim, (_account, _cumulative, _beneficiary))
        );
        IExecutor(address(dao)).execute(bytes32(0), _actions, 0);
    }
}

/// @notice Stream → pay each recipient its weight
contract MinimalPayroll is ITrigger {
    IDAO public dao;
    FundedStreamBudget public budget;
    address[] public recipients;
    uint32[] public weights;

    constructor(IDAO _dao, FundedStreamBudget _budget, address[] memory _recipients, uint32[] memory _weights) {
        (dao, budget, recipients, weights) = (_dao, _budget, _recipients, _weights);
    }

    function trigger(bytes calldata, bytes[] calldata) external {
        IERC20 _token = budget.token();
        (uint256 _amount,) = budget.available(msg.sender, "");
        uint256 _count = recipients.length;

        Action[] memory _actions = new Action[](_count + 1);
        uint256 _assigned;
        for (uint256 i; i < _count; ++i) {
            uint256 _share = i == _count - 1 ? _amount - _assigned : (_amount * weights[i]) / RATIO_BASE;
            _assigned += _share;
            _actions[i] = _transfer(_token, recipients[i], _share);
        }
        _actions[_count] = Action(address(budget), 0, abi.encodeCall(FundedStreamBudget.writeCheckpoint, ()));
        IExecutor(address(dao)).execute(bytes32(0), _actions, 0);
    }
}

// Raw: the token work alone. A contract holding the funds, no DAO, no budget, no checks.

contract RawSwap is ITrigger {
    IERC20 public offered;
    IERC20 public demanded;
    uint256 public amount;
    uint256 public demandPerFill;
    address public fee;
    uint32 public feeWeight;

    constructor(
        IERC20 _offered,
        IERC20 _demanded,
        uint256 _amount,
        uint256 _demandPerFill,
        address _fee,
        uint32 _feeWeight
    ) {
        (offered, demanded, amount, demandPerFill, fee, feeWeight) =
        (_offered, _demanded, _amount, _demandPerFill, _fee, _feeWeight);
    }

    function trigger(bytes calldata, bytes[] calldata) external {
        uint256 _amount = amount;
        uint256 _demand = demandPerFill;
        uint256 _fee = (_demand * feeWeight) / RATIO_BASE;

        offered.approve(msg.sender, _amount);
        IFiller(msg.sender).fillOffer(offered, _amount, demanded, _demand, "");
        offered.approve(msg.sender, 0);
        ERC20Burnable(address(demanded)).burn(_demand - _fee);
        if (_fee != 0) demanded.transfer(fee, _fee);
    }
}

/// @notice A standalone cumulative Merkle distributor holding the tokens
contract RawClaim is ITrigger {
    IERC20 public token;
    bytes32 public root;
    mapping(address => uint256) public claimed;

    constructor(IERC20 _token, bytes32 _root) {
        (token, root) = (_token, _root);
    }

    function trigger(bytes calldata _budgetData, bytes[] calldata) external {
        (address _account, uint256 _cumulative, bytes32[] memory _proof, address _beneficiary) =
            abi.decode(_budgetData, (address, uint256, bytes32[], address));
        require(msg.sender == _account);
        require(MerkleProof.verify(_proof, root, keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))))));
        uint256 _owed = _cumulative - claimed[_account];
        claimed[_account] = _cumulative;
        token.transfer(_beneficiary == address(0) ? _account : _beneficiary, _owed);
    }
}

contract RawPayroll is ITrigger {
    IERC20 public token;
    uint256 public amount;
    address[] public recipients;
    uint32[] public weights;

    constructor(IERC20 _token, uint256 _amount, address[] memory _recipients, uint32[] memory _weights) {
        (token, amount, recipients, weights) = (_token, _amount, _recipients, _weights);
    }

    function trigger(bytes calldata, bytes[] calldata) external {
        uint256 _amount = amount;
        uint256 _count = recipients.length;
        uint256 _assigned;
        for (uint256 i; i < _count; ++i) {
            uint256 _share = i == _count - 1 ? _amount - _assigned : (_amount * weights[i]) / RATIO_BASE;
            _assigned += _share;
            token.transfer(recipients[i], _share);
        }
    }
}

/// @notice Gas of each recipe run through the pipeline, next to a hand-written plugin with the same
///         budget (Minimal) and the bare token work (Raw).
/// @dev Run with `forge test --match-path test/gas/RecipeGas.t.sol --isolate -vv`: every call is then
///      its own transaction (cold storage, 21k intrinsic and calldata included). Steady state: every
///      recipient and the filler already hold some of each token. Reported gas is net of refunds.
contract RecipeGasTest is Fixture {
    uint256 internal constant FLOW_AMOUNT = RATE; // one epoch of stream
    uint32 internal constant FEE_WEIGHT = 50_000; // 5%
    uint256 internal constant PROOF_DEPTH = 10; // ~1,000 claimants

    LeanFiller internal filler;

    function setUp() public override {
        super.setUp();
        filler = new LeanFiller();
        tokenB.mint(address(filler), 100 * DEMAND);
        _dust(address(filler));
        _dust(fee);
        _dust(alice);
    }

    // Buy and burn: stream → OpenFill → burn

    function test_Gas_BuyAndBurn_Pipeline() public {
        FundedStreamBudget _budget = _deployBudget(RATE, STREAM_CAP);
        _measureFill(
            "buyAndBurn", "pipeline", ITrigger(address(_deployPlugin(_budget, _chain(_deployAction(_budget), burn))))
        );
    }

    function test_Gas_BuyAndBurn_Minimal() public {
        _measureFill("buyAndBurn", "minimal", _minimalSwap(0));
    }

    function test_Gas_BuyAndBurn_Raw() public {
        _measureFill("buyAndBurn", "raw", _rawSwap(0));
    }

    // Buyback: stream → OpenFill → 95% burn, 5% fee

    function test_Gas_Buyback_Pipeline() public {
        FundedStreamBudget _budget = _deployBudget(RATE, STREAM_CAP);
        Node[] memory _tree = _fork(_deployAction(_budget), 950_000, burn, 50_000, _deployTransfer(fee));
        _measureFill("buyback", "pipeline", ITrigger(address(_deployPlugin(_budget, _tree))));
    }

    function test_Gas_Buyback_Minimal() public {
        _measureFill("buyback", "minimal", _minimalSwap(FEE_WEIGHT));
    }

    function test_Gas_Buyback_Raw() public {
        _measureFill("buyback", "raw", _rawSwap(FEE_WEIGHT));
    }

    // Merkle claim → pay the beneficiary

    function test_Gas_MerkleClaim_Pipeline() public {
        (bytes32 _root, bytes memory _alice, bytes memory _bob) = _claims();
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployMerkle(tokenA, _root), _one(toBeneficiary));
        _measureClaim("pipeline", ITrigger(address(_plugin)), _alice, _bob);
    }

    function test_Gas_MerkleClaim_Minimal() public {
        (bytes32 _root, bytes memory _alice, bytes memory _bob) = _claims();
        MinimalClaim _minimal = new MinimalClaim(dao, _deployMerkle(tokenA, _root));
        dao.grant(address(dao), address(_minimal), dao.EXECUTE_PERMISSION_ID());
        _measureClaim("minimal", _minimal, _alice, _bob);
    }

    function test_Gas_MerkleClaim_Raw() public {
        (bytes32 _root, bytes memory _alice, bytes memory _bob) = _claims();
        RawClaim _raw = new RawClaim(tokenA, _root);
        tokenA.mint(address(_raw), DAO_A);
        _measureClaim("raw", _raw, _alice, _bob);
    }

    // Payroll: stream → one transfer per recipient

    function test_Gas_Payroll_Pipeline() public {
        uint256[3] memory _sizes = [uint256(2), 5, 15];
        for (uint256 s; s < _sizes.length; ++s) {
            uint256 _state = vm.snapshotState();
            (address[] memory _to, uint32[] memory _weights) = _recipients(_sizes[s]);
            FundedStreamBudget _budget = _deployBudget(RATE, 0);
            _measurePayroll(
                _sizes[s], "pipeline", ITrigger(address(_deployPlugin(_budget, _payrollTree(_to, _weights))))
            );
            vm.revertToState(_state);
        }
    }

    function test_Gas_Payroll_Minimal() public {
        uint256[3] memory _sizes = [uint256(2), 5, 15];
        for (uint256 s; s < _sizes.length; ++s) {
            uint256 _state = vm.snapshotState();
            (address[] memory _to, uint32[] memory _weights) = _recipients(_sizes[s]);
            MinimalPayroll _minimal = new MinimalPayroll(dao, _deployBudget(RATE, 0), _to, _weights);
            dao.grant(address(dao), address(_minimal), dao.EXECUTE_PERMISSION_ID());
            _measurePayroll(_sizes[s], "minimal", _minimal);
            vm.revertToState(_state);
        }
    }

    function test_Gas_Payroll_Raw() public {
        uint256[3] memory _sizes = [uint256(2), 5, 15];
        for (uint256 s; s < _sizes.length; ++s) {
            uint256 _state = vm.snapshotState();
            (address[] memory _to, uint32[] memory _weights) = _recipients(_sizes[s]);
            RawPayroll _raw = new RawPayroll(tokenA, FLOW_AMOUNT, _to, _weights);
            tokenA.mint(address(_raw), DAO_A);
            _measurePayroll(_sizes[s], "raw", _raw);
            vm.revertToState(_state);
        }
    }

    // Measuring

    /// @dev Every measured run is the second one, so first-run writes (the plugin's nonce) don't count
    function _measureFill(string memory _flow, string memory _tier, ITrigger _target) internal {
        vm.warp(block.timestamp + EPOCH);
        filler.fill(_target);

        vm.warp(block.timestamp + EPOCH);
        uint256 _supply = tokenB.totalSupply();
        filler.fill(_target);
        uint256 _gas = _netGas();

        assertEq(tokenA.balanceOf(address(filler)), 2 * FLOW_AMOUNT + 1, "filler got both offers");
        assertLt(tokenB.totalSupply(), _supply, "proceeds burned");
        console.log(string.concat("GAS ", _flow, " ", _tier), _gas);
    }

    /// @dev Bob claims first; alice's measured claim is still her first
    function _measureClaim(string memory _tier, ITrigger _target, bytes memory _aliceData, bytes memory _bobData)
        internal
    {
        vm.prank(bob);
        _target.trigger(_bobData, new bytes[](0));

        vm.prank(alice);
        _target.trigger(_aliceData, new bytes[](0));
        uint256 _gas = _netGas();

        assertEq(tokenA.balanceOf(alice), FLOW_AMOUNT + 1, "alice paid");
        console.log(string.concat("GAS merkleClaim ", _tier), _gas);
    }

    function _measurePayroll(uint256 _count, string memory _tier, ITrigger _target) internal {
        vm.warp(block.timestamp + EPOCH);
        _target.trigger("", new bytes[](0));

        vm.warp(block.timestamp + EPOCH);
        _target.trigger("", new bytes[](0));
        uint256 _gas = _netGas();

        console.log(string.concat("GAS payroll-", vm.toString(_count), " ", _tier), _gas);
    }

    /// @dev What the last call's transaction paid: used gas minus the capped refund (EIP-3529)
    function _netGas() internal view returns (uint256) {
        Vm.Gas memory _gas = vm.lastFrameGas();
        uint256 _used = _gas.gasTotalUsed;
        uint256 _refund = _gas.gasRefunded > 0 ? uint256(uint64(_gas.gasRefunded)) : 0;
        if (_refund > _used / 5) _refund = _used / 5;
        return _used - _refund;
    }

    // Setup helpers

    function _minimalSwap(uint32 _feeWeight) internal returns (MinimalSwap _minimal) {
        FundedStreamBudget _budget = _deployBudget(RATE, STREAM_CAP);
        _minimal = new MinimalSwap(dao, _budget, tokenB, DEMAND, fee, _feeWeight);
        dao.grant(address(dao), address(_minimal), dao.EXECUTE_PERMISSION_ID());
    }

    function _rawSwap(uint32 _feeWeight) internal returns (RawSwap _raw) {
        _raw = new RawSwap(tokenA, tokenB, FLOW_AMOUNT, DEMAND, fee, _feeWeight);
        tokenA.mint(address(_raw), DAO_A);
        tokenB.mint(address(_raw), DAO_B);
    }

    /// @dev Alice's and bob's claims of FLOW_AMOUNT: sibling leaves in a synthetic tree PROOF_DEPTH
    ///      levels deep
    function _claims() internal view returns (bytes32 _root, bytes memory _aliceData, bytes memory _bobData) {
        bytes32 _aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, FLOW_AMOUNT))));
        bytes32 _bobLeaf = keccak256(bytes.concat(keccak256(abi.encode(bob, FLOW_AMOUNT))));
        bytes32[] memory _aliceProof = new bytes32[](PROOF_DEPTH);
        bytes32[] memory _bobProof = new bytes32[](PROOF_DEPTH);
        (_aliceProof[0], _bobProof[0]) = (_bobLeaf, _aliceLeaf);
        _root = _hashPair(_aliceLeaf, _bobLeaf);
        for (uint256 i = 1; i < PROOF_DEPTH; ++i) {
            _aliceProof[i] = _bobProof[i] = keccak256(abi.encode("sibling", i));
            _root = _hashPair(_root, _aliceProof[i]);
        }
        _aliceData = abi.encode(alice, FLOW_AMOUNT, _aliceProof, address(0));
        _bobData = abi.encode(bob, FLOW_AMOUNT, _bobProof, address(0));
    }

    function _hashPair(bytes32 _a, bytes32 _b) internal pure returns (bytes32) {
        return _a < _b ? keccak256(abi.encode(_a, _b)) : keccak256(abi.encode(_b, _a));
    }

    function _recipients(uint256 _count) internal returns (address[] memory _to, uint32[] memory _weights) {
        _to = new address[](_count);
        _weights = new uint32[](_count);
        uint256 _assigned;
        for (uint256 i; i < _count; ++i) {
            _to[i] = makeAddr(string.concat("recipient", vm.toString(i)));
            _dust(_to[i]);
            _weights[i] = uint32(RATIO_BASE / _count);
            _assigned += _weights[i];
        }
        _weights[0] += uint32(RATIO_BASE - _assigned);
    }

    /// @dev Recipes.payroll: a root without an action splitting into one Transfer leaf per recipient.
    ///      The leaves are clones of one implementation, as the registry deploys them.
    function _payrollTree(address[] memory _to, uint32[] memory _weights) internal returns (Node[] memory _tree) {
        address _implementation = address(new TransferAction());
        uint256 _count = _to.length;
        _tree = new Node[](1 + _count);
        _tree[0].children = new uint32[](_count);
        _tree[0].weights = _weights;
        for (uint256 i; i < _count; ++i) {
            _tree[0].children[i] = uint32(1 + i);
            _tree[1 + i] = _leaf(
                INodeAction(
                    ProxyLib.deployMinimalProxy(
                        _implementation, abi.encodeCall(TransferAction.initialize, (dao, _to[i]))
                    )
                )
            );
        }
    }

    /// @dev Steady state: the account already holds some of each token
    function _dust(address _account) internal {
        tokenA.mint(_account, 1);
        tokenB.mint(_account, 1);
    }
}
