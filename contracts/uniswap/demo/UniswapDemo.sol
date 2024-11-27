
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract UniswapDemo {
    IUniswapV2Router02 public uniswapRouter;
    address public tokenA;
    address public tokenB;

    constructor(address _router, address _tokenA, address _tokenB) {
        uniswapRouter = IUniswapV2Router02(_router);
        tokenA = _tokenA;
        tokenB = _tokenB;
    }

// 添加流动性
    function addLiquidity(uint256 amountA, uint256 amountB) external {
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).transferFrom(msg.sender, address(this), amountB);

        IERC20(tokenA).approve(address(uniswapRouter), amountA);
        IERC20(tokenB).approve(address(uniswapRouter), amountB);

        uniswapRouter.addLiquidity(
            tokenA,
            tokenB,
            amountA,
            amountB,
            0, // 最小代币 A 数量
            0, // 最小代币 B 数量
            msg.sender,
            block.timestamp
        );
    }

// 移除流动性
    function removeLiquidity(uint256 liquidity) external {
// 需要提供流动性池的 LP 代币地址
        address pair = IUniswapV2Factory(uniswapRouter.factory()).getPair(tokenA, tokenB);
        IERC20(pair).transferFrom(msg.sender, address(this), liquidity);
        IERC20(pair).approve(address(uniswapRouter), liquidity);

        uniswapRouter.removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            0, // 最小代币 A 数量
            0, // 最小代币 B 数量
            msg.sender,
            block.timestamp
        );
    }

// 交换代币
    function swapTokens(uint256 amountIn, uint256 amountOutMin) external {
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenA).approve(address(uniswapRouter), amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;

        uniswapRouter.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            msg.sender,
            block.timestamp
        );
    }
}
