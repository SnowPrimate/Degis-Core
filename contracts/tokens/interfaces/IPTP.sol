pragma solidity ^0.8.13;

interface IPTP {
    function swap(address fromToken, address toToken, uint256 fromAmount, uint256 minimumToAmount, address to, uint256 deadline) external;

    function quotePotentialSwap(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256 potentialOutcome, uint256 haircut);

}