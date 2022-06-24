// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.4;

/**
 * @title Storage
 * @dev Store & retrieve value in a variable
 * @custom:dev-run-script ./scripts/deploy_with_ethers.ts
 */

import './Interfaces/IERC20.sol';
import './Utils/Hash.sol';
import './Utils/Sig.sol';

library Cast {
    /// @dev Safely cast an uint256 to an uint128
    /// @param n the u256 to cast to u128
    function u128(uint256 n) internal pure returns (uint128) {
        require(n <= type(uint128).max, ''); // TODO err msgs
        return uint128(n);
    }
}

interface IUniswapRouter {
    function swapExactTokensForTokens(uint256 amount, uint256 min, address[] calldata, address to, uint256 deadline) external;

}

interface ISwivelRouter {
    function initiate(Hash.Order[] calldata o, uint256[] calldata a, Sig.Components[] calldata c) external returns(bool);
    function exit(Hash.Order[] calldata o, uint256[] calldata a, Sig.Components[] calldata c) external returns(bool);
    function redeemZcToken(address, uint256, uint256 ) external returns (bool);
}

interface IYieldPool {
        function buyBase(address from, address to, uint128 daiIn) external returns(uint128);
        function buyBasePreview(uint128 baseOut) external view returns (uint128 fyTokenIn);
        function sellFYTokenPreview(uint128 fyTokenOut) external view   returns (uint128 baseIn);
        function sellFYToken(address to, uint128 min) external   returns (uint128 baseOut);
}

interface ISenseRouter {
    function swapUnderlyingForYTs(
        address adapter,
        uint256 maturity,
        uint256 underlyingIn,
        uint256 targetToBorrow,
        uint256 minOut
    ) external returns (uint256 targetBal, uint256 ytBal);

    function swapUnderlyingForPTs(
        address adapter,
        uint256 maturity,
        uint256 uBal,
        uint256 minAccepted
    ) external returns (uint256 ptBal);
    function combine(
        address adapter,
        uint256 maturity,
        uint256 uBal
    ) external;
}

interface ICToken {
    function borrow(uint borrowAmount) external returns (uint);
}

contract RateTrader {

    address pendle;
    address swivel;
    address sensePeriphery;
    address senseDivider;
    address uniswap;


    constructor(address pendleRouter, address swivelRouter, address periphery, address divider, address uniswapRouter) {
        pendle = pendleRouter;
        swivel = swivelRouter;
        sensePeriphery = periphery;
        senseDivider = divider;
        uniswap = uniswapRouter;
    }

    function stablecoinReversion(Hash.Order[] memory USDCOrders, uint256[] memory USDCAmounts, Sig.Components[] memory USDCSignatures,
    Hash.Order[] calldata DAIOrders, uint256[] calldata amounts, Sig.Components[] calldata signatures) 
    public returns (bool) {
        // Calculate USDC amount returned
        uint256 USDCAmount;
        for (uint256 i=0; i < USDCOrders.length; i++) {
            Hash.Order memory order = USDCOrders[i];
            uint256 amount = USDCAmounts[i];
            USDCAmount += amount;
        }
        // Fill Swivel orders, selling USDC PTs
        ISwivelRouter(swivel).exit(USDCOrders, USDCAmounts, USDCSignatures);
        address[] memory path = new address[](2);
        path[0] = USDCOrders[0].underlying;
        path[1] = DAIOrders[0].underlying;
        // approve uniswap to take USDC
        IERC20(USDCOrders[0].underlying).approve(uniswap, USDCAmount);
        // Swap from USDC to DAI on uniswap
        IUniswapRouter(uniswap).swapExactTokensForTokens(USDCAmount, USDCAmount, path, address(this), block.timestamp);
        // Fill Swivel orders, selling lending DAI for a fixed rate, now holding DAI PTs
        ISwivelRouter(swivel).exit(USDCOrders, USDCAmounts, USDCSignatures);

        return(true);
    }

    function PTArbitrage(Hash.Order[] calldata orders, uint256[] calldata amounts, Sig.Components[] calldata signatures, 
    address pool, address fyToken) public returns (uint256) {
        uint256 starting = IERC20(orders[0].underlying).balanceOf(address(this));
        // Calculate total amount of PT purchased from Swivel
        uint256 totalLent;
        for (uint256 i=0; i < orders.length; i++) {
            Hash.Order memory order = orders[i];
            uint256 amount = amounts[i];
            totalLent += amount;
        }
        // Preview the yield transaction using the swivel total
        uint128 returned = IYieldPool(pool).sellFYTokenPreview(Cast.u128(totalLent));
        // Transfer that amount to the yield pool
        IERC20(fyToken).transfer(pool, totalLent);
        // Sell the FYTokens on Yield
        IYieldPool(pool).sellFYToken(address(this), returned);
        // Approve Swivel to take underlying
        IERC20(orders[0].underlying).approve(swivel, totalLent);
        // Fill Swivel orders, lending at a fixed-rate on swivel and holding Swivel PTs
        ISwivelRouter(swivel).initiate(orders, amounts, signatures);
        // Calculate arb profit off of starting balance
        return (IERC20(orders[0].underlying).balanceOf(address(this)) - starting);
    }

    function internalArbitrage(uint256 maturity, address underlying, address adapter, uint256 ptAmount, 
        uint256 ytAmount, uint256 target, uint256 ytOut) 
        public returns (uint256) 
        {
        uint256 starting = IERC20(underlying).balanceOf(address(this));
        // purchase ptAmount of Sense PTs
        uint256 pt = ISenseRouter(sensePeriphery).swapUnderlyingForPTs(adapter, maturity, ptAmount, ptAmount);
        // purchase ytAmount of Sense YTs
        ISenseRouter(sensePeriphery).swapUnderlyingForYTs(adapter, maturity, ytAmount, target, ytOut);
        // combine sense YTs and PTs back to underlying
        ISenseRouter(senseDivider).combine(adapter, maturity, pt);
        // calculate the profit made by the arbitrage
        return (IERC20(underlying).balanceOf(address(this)) - starting);
    }

    // Long the rates on swivel while borrowing and fixing your rate
    function longAndFix(Hash.Order[] calldata orders, uint256[] calldata amounts, Sig.Components[] calldata signatures, address cToken) public returns (bool) {
        // Calculate total amount of cToken exposure purchased
        uint256 totalLent;
        for (uint256 i=0; i < orders.length; i++) {
            Hash.Order memory order = orders[i];
            uint256 amount = amounts[i];
            totalLent += amount;
        }
        // Borrow equivalent amount of cToken exposure
        ICToken(cToken).borrow(totalLent);
        // Fill Swivel orders, resulting in equal borrow and supply exposure
        ISwivelRouter(swivel).initiate(orders, amounts, signatures);
        return (true);
    }


}