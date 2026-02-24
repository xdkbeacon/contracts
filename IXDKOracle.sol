// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IXDKOracle {
    function genPrice() external;
    function price() external view returns(uint256);
    function priceTime(uint256 timestamp) external view returns(uint256);
    function bnbPrice() external view  returns (uint256);
    function gpcPrice() external view  returns (uint256);
}