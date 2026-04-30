// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITWAPSource } from "../../src/OracleAdapter.sol";

contract MockTWAPSource is ITWAPSource {
    uint256 public price;

    constructor(uint256 price_) {
        price = price_;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function consultTWAP(uint32) external view returns (uint256) {
        return price;
    }
}
