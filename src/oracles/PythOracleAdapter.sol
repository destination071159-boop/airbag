// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

interface IPyth {
  struct Price {
    int64 price;
    uint64 conf;
    int32 expo;
    uint256 publishTime;
  }

  function getPriceUnsafe(bytes32 id) external view returns (Price memory);
}

/// @notice Wraps a Pyth price feed as a Airbag IPriceOracle, normalized to `decimals`.
/// @dev Pyth reports price * 10^expo (expo usually negative). We rescale to an integer scaled by
///      10^decimals so it matches the market's pegPrice convention.
contract PythOracleAdapter is IPriceOracle {
  IPyth public immutable pyth;
  bytes32 public immutable priceId;
  uint8 public immutable decimals;

  error InvalidPrice();

  constructor(address _pyth, bytes32 _priceId, uint8 _decimals) {
    pyth = IPyth(_pyth);
    priceId = _priceId;
    decimals = _decimals;
  }

  function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
    IPyth.Price memory p = pyth.getPriceUnsafe(priceId);
    if (p.price <= 0) revert InvalidPrice();
    uint256 raw = uint256(uint64(p.price));

    // target integer = raw * 10^(expo + decimals)
    int256 e = int256(p.expo) + int256(uint256(decimals));
    if (e >= 0) {
      price = raw * (10 ** uint256(e));
    } else {
      price = raw / (10 ** uint256(-e));
    }
    updatedAt = p.publishTime;
  }
}
