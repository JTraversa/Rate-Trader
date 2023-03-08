// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.4;

import './Interfaces/IERC20.sol';
import './Interfaces/IERC5095.sol';
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

interface ILender {
    function mint(
        uint8 p,
        address u,
        uint256 m,
        uint256 a
    ) external returns (bool);
}

interface IYieldPool {
        function buyBase(address to, uint128 max) external returns(uint128);
        function buyBasePreview(uint128 baseOut) external view returns (uint128 fyTokenIn);
        function sellBasePreview(uint128 baseIn) external view returns (uint128 fyTokenOut);
        function sellBase(address to, uint256 min) external returns(uint128);
        function buyBase(uint128 baseOut) external view returns (uint128 fyTokenIn);
        function sellFYTokenPreview(uint128 fyTokenOut) external view   returns (uint128 baseIn);
        function sellFYToken(address to, uint128 min) external   returns (uint128 baseOut);
}

contract RateTrader {
    address lender;

    enum Principals {
        Illuminate, // 0
        Swivel, // 1
        Yield, // 2
        Element, // 3
        Pendle, // 4
        Tempus, // 5
        Sense, // 6
        Apwine, // 7
        Notional // 8
    }

    constructor(address _lender) {
        lender = _lender;
    }

    function YieldArbitrage(address yield, address illuminate, address underlying, address yieldPT, address illuminatePT, uint128 amount) public returns (uint256) {

        // Calculate total amount of PT purchased from Yield
        uint128 yieldAmount = IYieldPool(yield).sellBasePreview(amount);

        // Transfer that amount to the yield pool
        IERC20(underlying).transfer(yield, amount);

        // Sell base on Yield
        IYieldPool(yield).sellBase(address(this), yieldAmount);

        // Mint using the lender
        ILender(lender).mint(uint8(Principals.Yield), underlying, IERC5095(illuminatePT).maturity(), yieldAmount);

        // Preview the sale of the minted iPTs to the illuminate pool
        uint128 proceeds = IYieldPool(illuminate).sellFYTokenPreview(yieldAmount);

        // Transfer iPTs to the illuminate pool
        IERC20(illuminatePT).transfer(illuminate, yieldAmount);

        // Sell iPTs to the illuminate pool
        IYieldPool(illuminate).sellFYToken(address(this), proceeds);

        require (proceeds > amount, 'non-profitable arbitrage attempt');

        return (proceeds - amount);
    }
}