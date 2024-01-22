// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./lib/BitMap.sol";

struct CellGene {
    uint256 id;
    uint32 livingCellTotal; //Living cell count
    uint64 bornBlock; // Birth block
    uint64 rentedCount;
    uint256 bornPrice;
    bytes32 evolveSeed; //Evolution random seed
    BitMaps.BitMap bitmap; //Original gene information
}

struct LifeGene {
    uint256 id;
    uint32 livingCellTotal; // Living cell count
    uint64 bornBlock; // Birth block
    uint64 remainWorkTime;
    uint256 bornPrice;
    bytes32 evolveSeed; // Evolution random seed
    BitMaps.BitMap bitmap; //Original gene information
    uint256[] parentTokenIds;
}

struct LifeCreationConfig {
    int256 soldBySwitch;
    int256 switchTime;
    int256 cellTargetRentPrice;
    int256 priceDecayPercent;
    int256 logisticLimit;
    int256 timeScale;
    int256 perTimeUnit;
}

struct CellAuction {
    uint256 startTime;
    uint256 maxSellable;
    uint256 startTokenID;
    uint256 sold;
    int256 targetPrice;
    int256 decayConstant;
    int256 perTimeUnit;
}

library Helps {
    function getEvolveSeed() internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    block.number,
                    msg.sender,
                    blockhash(block.timestamp - 1)
                )
            );
    }

    function getDigits(
        uint256 number
    ) internal pure returns (uint256 top, uint256 min, uint256 bottom) {
        // Create three masks to obtain different parts of the numbers
        uint256 mask1 = 0x7;
        //  00000111
        uint256 mask2 = 0x38;
        //  000111000
        uint256 mask3 = 0x1c0;
        //  111000000

        // Use the bitwise AND operator '&' and the right shift operator '>>' to obtain different parts of the numbers.
        uint256 digits1 = number & mask1;
        uint256 digits2 = (number & mask2) >> 3;
        uint256 digits3 = (number & mask3) >> 6;

        return (digits1, digits2, digits3);
    }
}
