// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBscPledgeOracle} from "../interface/IBscPledgeOracle.sol";
import {IDebtToken} from "../interface/IDebtToken.sol";
import {IERC20} from "../interface/IERC20.sol";
import {IUniswapV2Router02} from "../interface/IUniswapV2Router02.sol";
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
    uint256 constant internal calDecimal = 1e18;

    enum PoolState{MATCH, EXECUTION, FINISH, LIQUIDATION, UNDONE}

    PoolState constant defaultChoice = PoolState.MATCH;

    // struct
    /*池*/
    // 每个池的基本信息
    struct PoolBaseInfo {
        uint256 settleTime;
        uint256 endTime;
        uint256 interestRate;
        uint256 maxSupply;
        uint256 lendSupply;
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

    }
}
