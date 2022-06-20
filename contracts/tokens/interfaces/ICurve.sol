pragma solidity ^0.8.13;

// reference https://curve.readthedocs.io/exchange-pools.html

interface ICurve {
    // returns array of swappable coins within the pool
  function coins(uint256 i) external view returns (address);
  function exchange(
    int128 i,
    int128 j,
    uint256 dx,
    uint256 min_dy
  ) external;
  function exchange_underlying(
    int128 i,
    int128 j,
    uint256 dx,
    uint256 min_dy
  ) external;
  function get_dx_underlying(
    int128 i,
    int128 j,
    uint256 dy
  ) external view returns (uint256);
  function get_dy_underlying(
    int128 i,
    int128 j,
    uint256 dx
  ) external view returns (uint256);
  function get_dx(
    int128 i,
    int128 j,
    uint256 dy
  ) external view returns (uint256);
  function get_dy(
    int128 i,
    int128 j,
    uint256 dx
  ) external view returns (uint256);
  function get_virtual_price() external view returns (uint256);
}