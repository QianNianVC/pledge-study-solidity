// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract UniswapV2PriceOracle {
    address public factory;
    address public router;

    constructor(address _factory, address _router) {
        factory = _factory;
        router = _router;
    }

    function getTokenPrice(address tokenA, address tokenB) external view returns (uint price) {
        address pairAddress = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), "Pair not found");

        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint reserve0, uint reserve1,) = pair.getReserves();

        if (pair.token0() == tokenA) {
            price = reserve1 * (10 ** 18) / reserve0;
        } else {
            price = reserve0 * (10 ** 18) / reserve1;
        }
    }
}