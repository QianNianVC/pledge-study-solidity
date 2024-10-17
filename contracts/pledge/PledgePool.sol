// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBscPledgeOracle} from "../interface/IBscPledgeOracle.sol";
import {IDebtToken} from "../interface/IDebtToken.sol";
import {IERC20} from "../interface/IERC20.sol";
import {SafeERC20} from "../library/SafeErc20.sol";
import {SafeMath} from "../library/SafeMath.sol";
import {SafeTransfer} from "../library/SafeTransfer.sol";
import {multiSignatureClient} from "../multiSignature/multiSignatureClient.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// 多签
// 防重入攻击

/**
 * @dev 核心合约
 */
contract PledgePool is ReentrancyGuard, SafeTransfer, multiSignatureClient {

    using SafeMath for uint256; // ^0.8.0后自带溢出检查
    using SafeERC20 for IERC20;
    uint256 constant internal calDecimal = 1e18; // default decimal
    uint256 constant internal baseDecimal = 1e8;
    uint256 public minAmount = 100e18;
    uint256 constant baseYear = 365 days; // one year

    enum PoolState{MATCH, EXECUTION, FINISH, LIQUIDATION, UNDONE}
    PoolState constant defaultChoice = PoolState.MATCH;

    bool public globalPaused = false;
    address public swapRouter; // pancake swap router
    address payable public feeAddress; // receiving fee address
    IBscPledgeOracle public oracle; // oracle address

    // fee
    uint256 public lendFee;
    uint256 public borrowFee;

    // struct
    /*池*/
    // 每个池的基本信息
    struct PoolBaseInfo {
        uint256 settleTime;
        uint256 endTime;
        uint256 interestRate;
        uint256 maxSupply;
        uint256 lendSupply;
        uint256 borrowSupply;
        uint256 martgageRate; // 池的抵押率，单位是1e8 (1e8)
        address lendToken;
        address borrowToken;
        PoolState state;
        IDebtToken spCoin;    // sp_token的erc20地址 (比如 spBUSD_1..)
        IDebtToken jpCoin;    // jp_token的erc20地址 (比如 jpBTC_1..)
        uint256 autoLiquidateThreshold; // 自动清算阈值（触发清算阈值）
    }

    PoolBaseInfo[] public poolBaseInfo;

    // 每个池的数据信息
    struct PoolDataInfo {
        uint256 settleAmountLend;       // 结算时的实际出借金额
        uint256 settleAmountBorrow;     // 结算时的实际借款金额
        uint256 finishAmountLend;       // 完成时的实际出借金额
        uint256 finishAmountBorrow;     // 完成时的实际借款金额
        uint256 liquidationAmountLend;   // 清算时的实际出借金额
        uint256 liquidationAmountBorrow; // 清算时的实际借款金额
    }

    PoolDataInfo[] public poolDataInfo;

    /*借款人Lend*/
    struct LendInfo {
        uint256 stakeAmount;
        uint256 refundAmount;
        bool hasNoRefund;       // 默认为false，false = 未退款，true = 已退款
        bool hasNoClaim;        // 默认为false，false = 未认领，true = 已认领
    }

    mapping(address => mapping(uint256 => LendInfo)) public userLendInfo;
    /*贷款人Borrow*/
    struct BorrowInfo {
        uint256 stakeAmount;
        uint256 refundAmount;
        bool hasNoRefund;
        bool hasNoClaim;
    }

    mapping(address => mapping(uint256 => BorrowInfo)) public userBorrowInfo;

    // 事件
    // 存款借出事件，from是借出者地址，token是借出的代币地址，amount是借出的数量，mintAmount是生成的数量
    event DepositLend(address indexed from, address indexed token, uint256 amount, uint256 mintAmount);
    // 借出退款事件，from是退款者地址，token是退款的代币地址，refund是退款的数量
    event RefundLend(address indexed from, address indexed token, uint256 refund);
    // 借出索赔事件，from是索赔者地址，token是索赔的代币地址，amount是索赔的数量
    event ClaimLend(address indexed from, address indexed token, uint256 amount);
    // 提取借出事件，from是提取者地址，token是提取的代币地址，amount是提取的数量，burnAmount是销毁的数量
    event WithdrawLend(address indexed from, address indexed token, uint256 amount, uint256 burnAmount);
    // 存款借入事件，from是借入者地址，token是借入的代币地址，amount是借入的数量，mintAmount是生成的数量
    event DepositBorrow(address indexed from, address indexed token, uint256 amount, uint256 mintAmount);
    // 借入退款事件，from是退款者地址，token是退款的代币地址，refund是退款的数量
    event RefundBorrow(address indexed from, address indexed token, uint256 refund);
    // 借入索赔事件，from是索赔者地址，token是索赔的代币地址，amount是索赔的数量
    event ClaimBorrow(address indexed from, address indexed token, uint256 amount);
    // 提取借入事件，from是提取者地址，token是提取的代币地址，amount是提取的数量，burnAmount是销毁的数量
    event WithdrawBorrow(address indexed from, address indexed token, uint256 amount, uint256 burnAmount);
    // 交换事件，fromCoin是交换前的币种地址，toCoin是交换后的币种地址，fromValue是交换前的数量，toValue是交换后的数量
    event Swap(address indexed fromCoin, address indexed toCoin, uint256 fromValue, uint256 toValue);
    // 紧急借入提取事件，from是提取者地址，token是提取的代币地址，amount是提取的数量
    event EmergencyBorrowWithdrawal(address indexed from, address indexed token, uint256 amount);
    // 紧急借出提取事件，from是提取者地址，token是提取的代币地址，amount是提取的数量
    event EmergencyLendWithdrawal(address indexed from, address indexed token, uint256 amount);
    // 状态改变事件，pid是项目id，beforeState是改变前的状态，afterState是改变后的状态
    event StateChange(uint256 indexed pid, uint256 indexed beforeState, uint256 indexed afterState);
    // 设置费用事件，newLendFee是新的借出费用，newBorrowFee是新的借入费用
    event SetFee(uint256 indexed newLendFee, uint256 indexed newBorrowFee);
    // 设置交换路由器地址事件，oldSwapAddress是旧的交换地址，newSwapAddress是新的交换地址
    event SetSwapRouterAddress(address indexed oldSwapAddress, address indexed newSwapAddress);
    // 设置费用地址事件，oldFeeAddress是旧的费用地址，newFeeAddress是新的费用地址
    event SetFeeAddress(address indexed oldFeeAddress, address indexed newFeeAddress);
    // 设置最小数量事件，oldMinAmount是旧的最小数量，newMinAmount是新的最小数量
    event SetMinAmount(uint256 indexed oldMinAmount, uint256 indexed newMinAmount);

    // 个人操作
    // 存入
    // 领取
    // 提取

    // 池子操作
    // 结算
    // 完成
    // 清算（达到阈值）
    // 结束

    // 辅助功能（扩展）
    // 多签
    // uniswap

    /** 理解这两个实体的作用
    IUniswapV2Router02 IUniswap = IUniswapV2Router02(_swapRouter);

    IBscPledgeOracle public oracle;
    oracle = IBscPledgeOracle(_oracle);
    */
    constructor(
        address _oracle,
        address _swapRouter,
        address payable _feeAddress,
        address _multiSignature
    ) {
        require(_oracle != address(0), "Is zero address");
        require(_swapRouter != address(0), "Is zero address");
        require(_feeAddress != address(0), "Is zero address");

        oracle = IBscPledgeOracle(_oracle);
        swapRouter = _swapRouter;
        feeAddress = _feeAddress;
        lendFee = 0;
        borrowFee = 0;
    }

    function setFee(uint256 _lendFee, uint256 _borrowFee) validCall external {
        lendFee = _lendFee;
        borrowFee = _borrowFee;
        emit SetFee(_lendFee, _borrowFee);
    }

    function setSwapRouterAddress(address _swapRouter) validCall external {
        require(_swapRouter != address(0), "Is zero address");
        emit SetSwapRouterAddress(swapRouter, _swapRouter);
        swapRouter = _swapRouter;
    }

    function setFeeAddress(address payable _feeAddress) validCall external {
        require(_feeAddress != address(0), "Is zero address");
        emit SetFeeAddress(feeAddress, _feeAddress);
        feeAddress = _feeAddress;
    }

    function setMinAmount(uint256 _minAmount) validCall external {
        emit setMinAmount(minAmount, _minAmount);
        minAmount = _minAmount;
    }

    function poolLength() external view returns (uint256) {
        return poolBaseInfo.length;
    }

    /*创建一个新的借贷池*/
    function createPoolInfo(uint256 _settleTime, uint256 _endTime, uint256 _interestRate, uint256 _maxSupply, uint256 _martgageRate,
        address _lendToken, address _borrowToken, address _spToken, address _jpToken, uint256 _autoLiquidateThreshold) public validCall {
        require(_endTime > _settleTime, "createPool: end time grate than settle time");
        require(_jpToken != address(0), "createPool: is zero address");
        require(_spToken != address(0), "createPool: is zero address");

        poolBaseInfo.push(PoolBaseInfo({
            settleTime: _settleTime,
            endTime: _endTime,
            interestRate: _interestRate,
            maxSupply: _maxSupply,
            lendSupply: 0,
            borrowSupply: 0,
            martgageRate: _martgageRate,
            lendToken: _lendToken,
            borrowToken: _borrowToken,
            state: defaultChoice,
            spCoin: IDebtToken(_spToken),
            jpCoin: IDebtToken(_jpToken),
            autoLiquidateThreshold: _autoLiquidateThreshold
        }));

        poolDataInfo.push(PoolDataInfo({
            settleAmountLend: 0,
            settleAmountBorrow: 0,
            finishAmountLend: 0,
            finishAmountBorrow: 0,
            liquidationAmountLend: 0,
            liquidationAmountBorrow: 0
        }));
    }

    function getPoolState(uint256 _pid) public view returns (uint256) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        return uint256(pool.state);
    }

    function depositLend(uint256 _pid, uint256 _stakeAmount) external payable nonReentrant notPause timeBefore(_pid) stateMatch(_pid) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid];

        require(_stakeAmount <= (pool.maxSupply).sub(pool.lendSupply), "depositLend: 数量超过限制");
        uint256 amount = getPayableAmount(pool.lendToken, _stakeAmount);
        require(amount > minAmount, "depositLend: 少于最小金额");

        lendInfo.hasNoClaim = false;
        lendInfo.hasNoRefund = false;
        if(pool.lendToken == address(0)) {
            lendInfo.stakeAmount = lendInfo.stakeAmount.add(msg.value);
            pool.lendSupply = pool.lendSupply.add(msg.value);
        } else {
            lendInfo.stakeAmount = lendInfo.stakeAmount.add(_stakeAmount);
            pool.lendSupply = pool.lendSupply.add(_stakeAmount);
        }
        emit DepositLend(msg.sender, pool.lendToken, _stakeAmount, amount);
    }

    function refundLend(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid];

        require(lendInfo.stakeAmount > 0, "refundLend: not pledged");
        require(pool.lendSupply.sub(data.settleAmountLend) > 0, "refundLend: not refund");
        require(!lendInfo.hasNoRefund, "refundLend: repeat refund");

        uint256 userShare = lendInfo.stakeAmount.mul(calDecimal).div(pool.lendSupply);
        uint256 refundAmount = (pool.lendSupply.sub(data.settleAmountLend)).mul(userShare).dic(calDecimal);
        _redeem(msg.sender, pool.lendSupply, refundAmount);

        lendInfo.hasNoRefund = true;
        lendInfo.refundAmount = lendInfo.refundAmount.add(refundAmount);
        emit RefundLend(msg.sender, pool.lendToken, refundAmount);
    }

    function claimLend(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid];

        require(lendInfo.stakeAmount > 0, "claimLend: 不能领取 sp_token");
        require(!lendInfo.hasNoClaim, "claimLend: 不能再次领取");

        uint256 userShare = lendInfo.stakeAmount.mul(calDecimal).div(pool.lendSupply);
        uint256 totalSpAmount = data.settleAmountLend;
        uint256 spAmount = totalSpAmount.mul(userShare).div(calDecimal);
        pool.spCoin.mint(msg.sender, spAmount);
        lendInfo.hasNoClaim = true;
        emit ClaimLend(msg.sender, pool.borrowToken, spAmount);
    }

    modifier notPause() {
        require(globalPaused == false, "Stake has been suspended");
        _;
    }


    modifier timeBefore(uint256 _pid) {
        require(block.timestamp < poolBaseInfo[_pid].settleTime, "Less than this time");
        _;
    }

    modifier timeAfter(uint256 _pid) {
        require(block.timestamp > poolBaseInfo[_pid].settleTime, "Greate than this time");
        _;
    }


    modifier stateMatch(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.MATCH, "state: Pool status is not equal to match");
        _;
    }

    modifier stateNotMatchUndone(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.EXECUTION || poolBaseInfo[_pid].state == PoolState.FINISH || poolBaseInfo[_pid].state == PoolState.LIQUIDATION, "state: not match and undone");
        _;
    }

    modifier stateFinishLiquidation(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.FINISH || poolBaseInfo[_pid].state == PoolState.LIQUIDATION, "state: finish liquidation");
        _;
    }

    modifier stateUndone(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.UNDONE, "state: state must be undone");
        _;
    }
}
