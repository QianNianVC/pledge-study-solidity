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
import {IUniswapV2Router02} from "../interface/IUniswapV2Router02.sol";

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

    function withdrawLend(uint256 _pid, uint256 _spAmount) external nonReentrant notPause stateFinishLiquidation(_pid) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        require(_spAmount > 0, 'withdrawLend: 取款金额为零');

        pool.spCoin.burn(msg.sender, _spAmount);
        uint256 totalSpAmount = data.settleAmountLend;
        uint256 spShare = _spAmount.mul(calDecimal).div(totalSpAmount);
        // 完成
        if (pool.state == PoolState.FINISH) {
            require(block.timestamp > pool.endTime, 'withdrawLend: 少于结束时间');
            uint256 redeemAmount = data.finishAmountLend.mul(spShare).div(calDecimal);
            _redeem(msg.sender, pool.lendToken, redeemAmount, _spAmount);
        }
        // 清算
        if (pool.state == PoolState.LIQUIDATION) {
            require(block.timestamp > pool.settleTime, 'withdrawLend: 少于匹配时间');
            uint256 redeemAmount = data.liquidationAmountLend.mul(spShare).div(calDecimal);
            _redeem(msg.sender, pool.lendToken, redeemAmount);
            emit WithdrawLend(msg.sender, pool.lendToken, redeemAmount, _spAmount);
        }
    }

    function emergencyLendWithdrawal(uint256 _pid) external nonReentrant notPause stateUndone(_pid) { // 池状态必须是未完成
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        require(pool.lendSupply > 0, "emergencyLend: not withdrawal");
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid];

        require(lendInfo.stakeAmount > 0, "refundLend: not pledged");
        require(!lendInfo.hasNoRefund, "refundLend: again refund");

        _redeem(msg.sender, pool.lendToken, lendInfo.stakeAmount);
        lendInfo.hasNoRefund = true;
        emit EmergencyLendWithdrawal(msg.sender, pool.lendToken, lendInfo.stakeAmount);
    }

    /**
  * @dev 借款人质押操作
     * @param _pid 是池子索引
     * @param _stakeAmount 是用户质押的数量
     */
    function depositBorrow(uint256 _pid, uint256 _stakeAmount) external payable nonReentrant notPause timeBefore(_pid) stateMatch(_pid) {
        // 基础信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池子基础信息
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid]; // 获取用户借款信息
        // 动作
        uint256 amount = getPayableAmount(pool.borrowToken, _stakeAmount); // 获取应付金额
        require(amount > 0, 'depositBorrow: deposit amount is zero'); // 要求质押金额大于0
        // 保存用户信息
        borrowInfo.hasNoClaim = false; // 设置用户未提取质押物
        borrowInfo.hasNoRefund = false; // 设置用户未退款
        // 更新信息
        if (pool.borrowToken == address(0)) { // 如果借款代币是0地址（即ETH）
            borrowInfo.stakeAmount = borrowInfo.stakeAmount.add(msg.value); // 更新用户质押金额
            pool.borrowSupply = pool.borrowSupply.add(msg.value); // 更新池子借款供应量
        } else { // 如果借款代币不是0地址（即其他ERC20代币）
            borrowInfo.stakeAmount = borrowInfo.stakeAmount.add(_stakeAmount); // 更新用户质押金额
            pool.borrowSupply = pool.borrowSupply.add(_stakeAmount); // 更新池子借款供应量
        }
        emit DepositBorrow(msg.sender, pool.borrowToken, _stakeAmount, amount); // 触发质押借款事件
    }

    /**
 * @dev 退还给借款人的过量存款，当借款人的质押量大于0，且借款供应量减去结算借款量大于0，且借款人没有退款时，计算退款金额并进行退款。
     * @notice 池状态不等于匹配和未完成
     * @param _pid 是池状态
     */
    function refundBorrow(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid) {
        // 基础信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池的基础信息
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池的数据信息
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid]; // 获取借款人的信息
        // 条件
        require(pool.borrowSupply.sub(data.settleAmountBorrow) > 0, "refundBorrow: not refund"); // 需要借款供应量减去结算借款量大于0
        require(borrowInfo.stakeAmount > 0, "refundBorrow: not pledged"); // 需要借款人的质押量大于0
        require(!borrowInfo.hasNoRefund, "refundBorrow: again refund"); // 需要借款人没有退款
        // 计算用户份额
        uint256 userShare = borrowInfo.stakeAmount.mul(calDecimal).div(pool.borrowSupply); // 用户份额等于借款人的质押量乘以计算小数点后的位数，然后除以借款供应量
        uint256 refundAmount = (pool.borrowSupply.sub(data.settleAmountBorrow)).mul(userShare).div(calDecimal); // 退款金额等于（借款供应量减去结算借款量）乘以用户份额，然后除以计算小数点后的位数
        // 动作
        _redeem(msg.sender, pool.borrowToken, refundAmount); // 赎回
        // 更新用户信息
        borrowInfo.refundAmount = borrowInfo.refundAmount.add(refundAmount); // 更新借款人的退款金额
        borrowInfo.hasNoRefund = true; // 设置借款人已经退款
        emit RefundBorrow(msg.sender, pool.borrowToken, refundAmount); // 触发退款事件
    }

    /**
  * @dev 借款人接收 sp_token 和贷款资金
     * @notice 池状态不等于匹配和未完成
     * @param _pid 是池状态
     */
    function claimBorrow(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid) {
        // 池基本信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid];
        // 限制
        require(borrowInfo.stakeAmount > 0, "claimBorrow: 没有索取 jp_token");
        require(!borrowInfo.hasNoClaim, "claimBorrow: 再次索取");
        // 总 jp 数量 = settleAmountLend * martgageRate
        uint256 totalJpAmount = data.settleAmountLend.mul(pool.martgageRate).div(baseDecimal);
        uint256 userShare = borrowInfo.stakeAmount.mul(calDecimal).div(pool.borrowSupply);
        uint256 jpAmount = totalJpAmount.mul(userShare).div(calDecimal);
        // 铸造 jp token
        pool.jpCoin.mint(msg.sender, jpAmount);
        // 索取贷款资金
        uint256 borrowAmount = data.settleAmountLend.mul(userShare).div(calDecimal);
        _redeem(msg.sender, pool.lendToken, borrowAmount);
        // 更新用户信息
        borrowInfo.hasNoClaim = true;
        emit ClaimBorrow(msg.sender, pool.borrowToken, jpAmount);
    }

    /**
  * @dev 借款人提取剩余的保证金，这个函数首先检查提取的金额是否大于0，然后销毁相应数量的JPtoken。接着，它计算JPtoken的份额，并根据池的状态（完成或清算）进行相应的操作。如果池的状态是完成，它会检查当前时间是否大于结束时间，然后计算赎回金额并进行赎回。如果池的状态是清算，它会检查当前时间是否大于匹配时间，然后计算赎回金额并进行赎回。
     * @param _pid 是池状态
     * @param _jpAmount 是用户销毁JPtoken的数量
     */
    function withdrawBorrow(uint256 _pid, uint256 _jpAmount) external nonReentrant notPause stateFinishLiquidation(_pid) {
        // 声明池基础信息和数据信息的存储
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        // 要求提取的金额大于0
        require(_jpAmount > 0, 'withdrawBorrow: withdraw amount is zero');
        // 销毁jp token
        pool.jpCoin.burn(msg.sender, _jpAmount);
        // jp份额
        uint256 totalJpAmount = data.settleAmountLend.mul(pool.martgageRate).div(baseDecimal);
        uint256 jpShare = _jpAmount.mul(calDecimal).div(totalJpAmount);
        // 完成状态
        if (pool.state == PoolState.FINISH) {
            // 要求当前时间大于结束时间
            require(block.timestamp > pool.endTime, "withdrawBorrow: less than end time");
            uint256 redeemAmount = jpShare.mul(data.finishAmountBorrow).div(calDecimal);
            _redeem(msg.sender, pool.borrowToken, redeemAmount);
            emit WithdrawBorrow(msg.sender, pool.borrowToken, _jpAmount, redeemAmount);
        }
        // 清算状态
        if (pool.state == PoolState.LIQUIDATION) {
            // 要求当前时间大于匹配时间
            require(block.timestamp > pool.settleTime, "withdrawBorrow: less than match time");
            uint256 redeemAmount = jpShare.mul(data.liquidationAmounBorrow).div(calDecimal);
            _redeem(msg.sender, pool.borrowToken, redeemAmount);
            emit WithdrawBorrow(msg.sender, pool.borrowToken, _jpAmount, redeemAmount);
        }
    }

    /**
  * @dev 紧急借款提取
     * @notice 在极端情况下，总存款为0，或者总保证金为0，在某些极端情况下，如总存款为0或总保证金为0时，借款者可以进行紧急提取。首先，代码会获取池子的基本信息和借款者的借款信息，然后检查借款供应和借款者的质押金额是否大于0，以及借款者是否已经进行过退款。如果这些条件都满足，那么就会执行赎回操作，并标记借款者已经退款。最后，触发一个紧急借款提取的事件。
     * @param _pid 是池子的索引
     */
    function emergencyBorrowWithdrawal(uint256 _pid) external nonReentrant notPause stateUndone(_pid) {
        // 获取池子的基本信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        // 确保借款供应大于0
        require(pool.borrowSupply > 0, "emergencyBorrow: not withdrawal");
        // 获取借款者的借款信息
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid];
        // 确保借款者的质押金额大于0
        require(borrowInfo.stakeAmount > 0, "refundBorrow: not pledged");
        // 确保借款者没有进行过退款
        require(!borrowInfo.hasNoRefund, "refundBorrow: again refund");
        // 执行赎回操作
        _redeem(msg.sender, pool.borrowToken, borrowInfo.stakeAmount);
        // 标记借款者已经退款
        borrowInfo.hasNoRefund = true;
        // 触发紧急借款提取事件
        emit EmergencyBorrowWithdrawal(msg.sender, pool.borrowToken, borrowInfo.stakeAmount);
    }

    function checkoutSettle(uint256 _pid) public view returns (bool) {
        return block.timestamp > poolBaseInfo[_pid].settleTime;
    }

    // 结算 （管理员操作 validCall）
    function settle(uint256 _pid) public validCall {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        require(block.timestamp > poolBaseInfo[_pid].settleTime, "settle: 小于结算时间");
        require(pool.state == PoolState.MATCH, "settle: 池子状态必须是匹配");
        if (pool.lendSupply > 0 && pool.borrowSupply > 0) {
            // 获取标的物价格
            uint256[2]memory prices = getUnderlyingPriceView(_pid);
            // 总保证金价值 = 保证金数量 * 保证金价格
            uint256 totalValue = pool.borrowSupply.mul(prices[1].mul(calDecimal).div(prices[0])).div(calDecimal);
            // 转换为稳定币价值
            uint256 actualValue = totalValue.mul(baseDecimal).div(pool.martgageRate);
            if (pool.lendSupply > actualValue) {
                // 总借款大于总借出
                data.settleAmountLend = actualValue;
                data.settleAmountBorrow = pool.borrowSupply;
            } else {
                // 总借款小于总借出
                data.settleAmountLend = pool.lendSupply;
                data.settleAmountBorrow = pool.lendSupply.mul(pool.martgageRate).div(prices[1].mul(baseDecimal).div(prices[0]));
            }
            // 更新池子状态
            pool.state = PoolState.EXECUTION;
            // 触发事件
            emit StateChange(_pid, uint256(PoolState.MATCH), uint256(PoolState.EXECUTION));
        } else {
            // 极端情况，借款或借出任一为0
            pool.state = PoolState.UNDONE;
            data.settleAmountLend = pool.lendSupply;
            data.settleAmountBorrow = pool.borrowSupply;
            // 触发事件
            emit StateChange(_pid, uint256(PoolState.MATCH), uint256(PoolState.UNDONE));
        }
    }

    function checkoutFinish(uint256 _pid) public view returns (bool){
        return block.timestamp > poolBaseInfo[_pid].endTime;
    }

    function finish(uint256 _pid) public validCall {
        // 获取基础池子信息和数据信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];

        // 验证当前时间是否大于池子的结束时间
        require(block.timestamp > poolBaseInfo[_pid].endTime, "finish: less than end time");
        // 验证池子的状态是否为执行状态
        require(pool.state == PoolState.EXECUTION, "finish: pool state must be execution");

        // 获取借款和贷款的token
        (address token0, address token1) = (pool.borrowToken, pool.lendToken);

        // 计算时间比率 = ((结束时间 - 结算时间) * 基础小数)/365天
        uint256 timeRatio = ((pool.endTime.sub(pool.settleTime)).mul(baseDecimal)).div(baseYear);

        // 计算利息 = 时间比率 * 利率 * 结算贷款金额
        uint256 interest = timeRatio.mul(pool.interestRate.mul(data.settleAmountLend)).div(1e16);

        // 计算贷款金额 = 结算贷款金额 + 利息
        uint256 lendAmount = data.settleAmountLend.add(interest);

        // 计算销售金额 = 贷款金额*(1+贷款费)
        uint256 sellAmount = lendAmount.mul(lendFee.add(baseDecimal)).div(baseDecimal);

        // 执行交换操作
        (uint256 amountSell,uint256 amountIn) = _sellExactAmount(swapRouter, token0, token1, sellAmount);

        // 验证交换后的金额是否大于等于贷款金额
        require(amountIn >= lendAmount, "finish: Slippage is too high");

        // 如果交换后的金额大于贷款金额，计算费用并赎回
        if (amountIn > lendAmount) {
            uint256 feeAmount = amountIn.sub(lendAmount);
            // 贷款费
            _redeem(feeAddress, pool.lendToken, feeAmount);
            data.finishAmountLend = amountIn.sub(feeAmount);
        } else {
            data.finishAmountLend = amountIn;
        }

        // 计算剩余的借款金额并赎回借款费
        uint256 remainNowAmount = data.settleAmountBorrow.sub(amountSell);
        uint256 remainBorrowAmount = redeemFees(borrowFee, pool.borrowToken, remainNowAmount);
        data.finishAmountBorrow = remainBorrowAmount;

        // 更新池子状态为完成
        pool.state = PoolState.FINISH;

        // 触发状态改变事件
        emit StateChange(_pid, uint256(PoolState.EXECUTION), uint256(PoolState.FINISH));
    }

    /**
   * @dev 检查清算条件,它首先获取了池子的基础信息和数据信息，然后计算了保证金的当前价值和清算阈值，最后比较了这两个值，如果保证金的当前价值小于清算阈值，那么就满足清算条件，函数返回true，否则返回false。
     * @param _pid 是池子的索引
     */
    function checkoutLiquidate(uint256 _pid) external view returns (bool) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取基础池信息
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池数据信息
        // 保证金价格
        uint256[2]memory prices = getUnderlyingPriceView(_pid); // 获取标的价格视图
        // 保证金当前价值 = 保证金数量 * 保证金价格
        uint256 borrowValueNow = data.settleAmountBorrow.mul(prices[1].mul(calDecimal).div(prices[0])).div(calDecimal);
        // 清算阈值 = settleAmountLend*(1+autoLiquidateThreshold)
        uint256 valueThreshold = data.settleAmountLend.mul(baseDecimal.add(pool.autoLiquidateThreshold)).div(baseDecimal);
        return borrowValueNow < valueThreshold; // 如果保证金当前价值小于清算阈值，则返回true，否则返回false
    }

    /**
 * @dev 清算
     * @param _pid 是池子的索引
     */
    function liquidate(uint256 _pid) public validCall {
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池子的数据信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池子的基本信息
        require(block.timestamp > pool.settleTime, "现在的时间小于匹配时间"); // 需要当前时间大于结算时间
        require(pool.state == PoolState.EXECUTION, "liquidate: 池子的状态必须是执行状态"); // 需要池子的状态是执行状态
        // sellamount
        (address token0, address token1) = (pool.borrowToken, pool.lendToken); // 获取借款和贷款的token
        // 时间比率 = ((结束时间 - 结算时间) * 基础小数)/365天
        uint256 timeRatio = ((pool.endTime.sub(pool.settleTime)).mul(baseDecimal)).div(baseYear);
        // 利息 = 时间比率 * 利率 * 结算贷款金额
        uint256 interest = timeRatio.mul(pool.interestRate.mul(data.settleAmountLend)).div(1e16);
        // 贷款金额 = 结算贷款金额 + 利息
        uint256 lendAmount = data.settleAmountLend.add(interest);
        // sellamount = lendAmount*(1+lendFee)
        // 添加贷款费用
        uint256 sellAmount = lendAmount.mul(lendFee.add(baseDecimal)).div(baseDecimal);
        (uint256 amountSell,uint256 amountIn) = _sellExactAmount(swapRouter, token0, token1, sellAmount); // 卖出准确的金额
        // 可能会有滑点，amountIn - lendAmount < 0;
        if (amountIn > lendAmount) {
            uint256 feeAmount = amountIn.sub(lendAmount); // 费用金额
            // 贷款费用
            _redeem(feeAddress, pool.lendToken, feeAmount);
            data.liquidationAmounLend = amountIn.sub(feeAmount);
        } else {
            data.liquidationAmounLend = amountIn;
        }
        // liquidationAmounBorrow  借款费用
        uint256 remianNowAmount = data.settleAmountBorrow.sub(amountSell); // 剩余的现在的金额
        uint256 remianBorrowAmount = redeemFees(borrowFee, pool.borrowToken, remianNowAmount); // 剩余的借款金额
        data.liquidationAmounBorrow = remianBorrowAmount;
        // 更新池子状态
        pool.state = PoolState.LIQUIDATION;
        // 事件
        emit StateChange(_pid, uint256(PoolState.EXECUTION), uint256(PoolState.LIQUIDATION));
    }

    function getUnderlyingPriceView(uint256 _pid) public view returns (uint256[2] memory) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        uint256[] memory assets = new uint256[](2);
        assets[0] = uint256(pool.lendToken);
        assets[1] = uint256(pool.borrowToken);
        uint256[] memory prices = oracle.getPrices(assets);
        return [prices[0], prices[]];
    }

    /**
   * @dev 费用计算,计算并赎回费用。首先，它计算费用，这是通过乘以费率并除以基数来完成的。如果计算出的费用大于0，它将从费用地址赎回相应的费用。最后，它返回的是原始金额减去费用。
     */
    function redeemFees(uint256 feeRatio, address token, uint256 amount) internal returns (uint256){
        // 计算费用，费用 = 金额 * 费率 / 基数
        uint256 fee = amount.mul(feeRatio) / baseDecimal;
        // 如果费用大于0
        if (fee > 0) {
            // 从费用地址赎回相应的费用
            _redeem(feeAddress, token, fee);
        }
        // 返回金额减去费用
        return amount.sub(fee);
    }

    function _sellExactAmount(address _swapRouter, address token0, address token1, uint256 amountout) internal returns (uint256, uint256){
        uint256 amountSell = amountout > 0 ? _getAmountIn(swapRouter, token0, token1, amountout) : 0;
        return (amountSell, _swap(_swapRouter, token0, token1, amountSell));
    }

    /**
     * @dev Get input based on output
      */
    function _getAmountIn(address _swapRouter, address token0, address token1, uint256 amountOut) internal view returns (uint256){
        IUniswapV2Router02 IUniswap = IUniswapV2Router02(_swapRouter);
        address[] memory path = _getSwapPath(swapRouter, token0, token1);
        uint[] memory amounts = IUniswap.getAmountsIn(amountOut, path);
        return amounts[0];
    }

    function _swap(address _swapRouter, address token0, address token1, uint256 amount0) internal returns (uint256) {
        if (token0 != address(0)) {
            _safeApprove(token0, address(_swapRouter), uint256(- 1));
        }
        if (token1 != address(0)) {
            _safeApprove(token1, address(_swapRouter), uint256(- 1));
        }
        IUniswapV2Router02 IUniswap = IUniswapV2Router02(_swapRouter);
        address[] memory path = _getSwapPath(_swapRouter, token0, token1);
        uint256[] memory amounts;
        if (token0 == address(0)) {
            amounts = IUniswap.swapExactETHForTokens{value: amount0}(0, path, address(this), block.timestamp + 30);
        } else if (token1 == address(0)) {
            amounts = IUniswap.swapExactTokensForETH(amount0, 0, path, address(this), block.timestamp + 30);
        } else {
            amounts = IUniswap.swapExactTokensForTokens(amount0, 0, path, address(this), block.timestamp + 30);
        }
        emit Swap(token0, token1, amounts[0], amounts[amounts.length - 1]);
        return amounts[amounts.length - 1];
    }

    function _getSwapPath(address _swapRouter, address token0, address token1) internal pure returns (address[] memory path){
        IUniswapV2Router02 IUniswap = IUniswapV2Router02(_swapRouter);
        path = new address[](2);
        path[0] = token0 == address(0) ? IUniswap.WETH() : token0;
        path[1] = token1 == address(0) ? IUniswap.WETH() : token1;
    }

    /**
     * @dev Approve
     */
    function _safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "!safeApprove");
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
