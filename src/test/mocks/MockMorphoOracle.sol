// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {IMorphoOracle} from "../../interfaces/IMorphoOracle.sol";

contract MockMorphoOracle is IMorphoOracle {
    uint256 internal _price;

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    function price() external view returns (uint256) {
        return _price;
    }
}
