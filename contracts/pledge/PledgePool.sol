// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MultiSigWallet} from "../multiSignature/v1/MultiSigWallet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// 多签
// 防重入攻击

/**
 * @dev 核心合约
 */
contract PledgePool is ReentrancyGuard, MultiSigWallet {

    // struct
    /*池*/
    // 每个池的基本信息
    struct PoolBaseInfo {
        uint256 settleTime;
        uint256 endTime;
        uint256 interestRate;
        uint256 maxSupply;
    }
    /*借款人Lend*/
    /*贷款人Borrow*/

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
    ){

    }
}
