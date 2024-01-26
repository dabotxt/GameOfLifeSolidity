// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/Strings.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {toWadUnsafe, toDaysWadUnsafe, wadLn} from "solmate/utils/SignedWadMath.sol";

import "./lib/VRGDA.sol";
import "./lib/BitMap.sol";
import "./Life.sol";
import "./Helps.sol";

contract CellGame is ERC721Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    using BitMaps for BitMaps.BitMap;

    uint256 constant MAX_RANDOM_NUM = 511;
    uint256 public constant BLOCK_TIME = 2; //Set the time for each block
    uint32 public constant EVOLUTION_TIME = 5 * 60; // Evolution time

    Life public _life;

    CellAuction public _currentCellAuction;
    LifeCreationConfig public _lifeCreationConfig;

    BitMaps.BitMap private _randomBitmap;
    uint256 public _current_round_number;

    mapping(uint256 => CellGene) _cellPool;

    uint256 public _cellMintedNum;

    mapping(uint256 tokenId => uint256) public _rentFeeCollected;

    string private _baseUrl;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        Life life_,
        string memory name_,
        string memory symbol_
    ) public initializer {
        _baseUrl = "https://api.cellula.life/token/";
        _life = life_;

        __ERC721_init(name_, symbol_);
        __Ownable_init(owner_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setLifeCreationConfig(
        int256 soldBySwitch_,
        int256 switchTime_,
        int256 cellTargetRentPrice_,
        int256 priceDecayPercent_,
        int256 logisticLimit_,
        int256 timeScale_,
        int256 perTimeUnit_,
        uint256 updateInterval_
    ) public onlyOwner {
        int256 decayConstant = wadLn(1e18 - priceDecayPercent_);
        require(decayConstant < 0, "NON_NEGATIVE_DECAY_CONSTANT");

        _lifeCreationConfig.soldBySwitch = soldBySwitch_;
        _lifeCreationConfig.switchTime = switchTime_;
        _lifeCreationConfig.cellTargetRentPrice = cellTargetRentPrice_;
        _lifeCreationConfig.decayConstant = decayConstant;
        _lifeCreationConfig.logisticLimit = logisticLimit_;
        _lifeCreationConfig.timeScale = timeScale_;
        _lifeCreationConfig.perTimeUnit = perTimeUnit_;
        _lifeCreationConfig.updateInterval = updateInterval_;
    }

    function getCellRentPrice(
        uint256 rentedCount,
        uint256 absoluteTimeSinceStart
    ) public view returns (uint256) {
        return
            VRGDA.getVRGDAPrice(
                toDaysWadUnsafe(
                    absoluteTimeSinceStart -
                        (absoluteTimeSinceStart %
                            _lifeCreationConfig.updateInterval)
                ),
                _lifeCreationConfig.cellTargetRentPrice,
                _lifeCreationConfig.decayConstant,
                // Theoretically calling toWadUnsafe with sold can silently overflow but under
                // any reasonable circumstance it will never be large enough. We use sold + 1 as
                // the VRGDA formula's n param represents the nth token and sold is the n-1th token.
                VRGDA.getTargetSaleTimeLogisticToLinear(
                    toWadUnsafe(rentedCount + 1),
                    _lifeCreationConfig.soldBySwitch,
                    _lifeCreationConfig.switchTime,
                    _lifeCreationConfig.logisticLimit,
                    _lifeCreationConfig.timeScale,
                    _lifeCreationConfig.perTimeUnit
                )
            );
    }

    function getLifePrice(
        uint256[] memory cells_
    ) public view returns (uint256[] memory cellsPrice) {
        require(
            cells_.length >= 2 && cells_.length <= 9,
            "can only use 2-9 cells!"
        );
        uint256[] memory usedCells = new uint256[](cells_.length);
        cellsPrice = new uint256[](cells_.length);
        for (uint i = 0; i < cells_.length; i++) {
            uint256 tokenId = cells_[i];
            CellGene storage cellGene = _cellPool[tokenId];
            uint256 rentedCount = cellGene.rentedCount;
            uint256 absoluteTimeSinceStart = block.timestamp -
                cellGene.bornTime;
            for (uint j = 0; j < i; j++) {
                if (usedCells[j] == tokenId) {
                    rentedCount++;
                }
            }
            uint256 cellRentPrice = getCellRentPrice(
                rentedCount,
                absoluteTimeSinceStart
            );
            usedCells[i] = tokenId;
            cellsPrice[i] = cellRentPrice;
        }

        return cellsPrice;
    }

    function createLife(uint256[][] memory cellsPositions_) public payable {
        require(
            cellsPositions_.length >= 2 && cellsPositions_.length <= 9,
            "can only use 2-9 cells!"
        );
        uint256 cumulatedPrice = 0;
        uint256[] memory cellGenes = new uint256[](cellsPositions_.length);
        uint32[] memory livingCellTotals = new uint32[](cellsPositions_.length);

        for (uint i = 0; i < cellsPositions_.length; i++) {
            uint256 tokenId = cellsPositions_[i][0];
            CellGene storage cellGene = _cellPool[tokenId];
            uint256 absoluteTimeSinceStart = block.timestamp -
                cellGene.bornTime;
            uint256 cellRentPrice = getCellRentPrice(
                cellGene.rentedCount,
                absoluteTimeSinceStart
            );

            cellGenes[i] = cellGene.bitmap.getBucket(0);
            livingCellTotals[i] = cellGene.livingCellTotal;
            cellGene.rentedCount += 1;
            _rentFeeCollected[tokenId] += (cellRentPrice * 70) / 100;
            cumulatedPrice += cellRentPrice;
        }

        require(msg.value >= cumulatedPrice, "Insufficient funds");

        _life.createLife(
            msg.sender,
            cumulatedPrice,
            cellsPositions_,
            cellGenes,
            livingCellTotals
        );

        if (msg.value > cumulatedPrice) {
            (bool sent, ) = payable(msg.sender).call{
                value: msg.value - cumulatedPrice
            }(""); // Returns false on failure
            require(sent, "failed to return Ether");
        }
    }

    function getCurrentVRGDAPrice() public view returns (uint256) {
        uint256 absoluteTimeSinceStart = block.timestamp -
            _currentCellAuction.startTime;

        return
            VRGDA.getVRGDAPrice(
                toDaysWadUnsafe(
                    absoluteTimeSinceStart -
                        (absoluteTimeSinceStart %
                            _currentCellAuction.updateInterval)
                ),
                _currentCellAuction.targetPrice,
                _currentCellAuction.decayConstant,
                // Theoretically calling toWadUnsafe with sold can silently overflow but under
                // any reasonable circumstance it will never be large enough. We use sold + 1 as
                // the VRGDA formula's n param represents the nth token and sold is the n-1th token.
                VRGDA.getTargetSaleTimeLinear(
                    toWadUnsafe(_currentCellAuction.sold + 1),
                    _currentCellAuction.perTimeUnit
                )
            );
    }

    function addNewAuction(
        int256 targetPrice_,
        int256 priceDecayPercent_,
        int256 perTimeUnit_,
        uint256 startTime_,
        uint256 maxSellable_,
        uint256 startTokenID_,
        uint256 updateInterval_
    ) public onlyOwner {
        require(
            _currentCellAuction.sold == _currentCellAuction.maxSellable,
            "auction ongoing"
        );
        require(startTime_ > block.timestamp, "invalid startTime");
        int256 decayConstant = wadLn(1e18 - priceDecayPercent_);
        require(decayConstant < 0, "NON_NEGATIVE_DECAY_CONSTANT");

        _currentCellAuction.startTime = startTime_;
        _currentCellAuction.targetPrice = targetPrice_;
        _currentCellAuction.decayConstant = decayConstant;
        _currentCellAuction.perTimeUnit = perTimeUnit_;
        _currentCellAuction.maxSellable = maxSellable_;
        _currentCellAuction.startTokenID = startTokenID_;
        _currentCellAuction.updateInterval = updateInterval_;
    }

    function mintFromAuction() public payable {
        require(
            _currentCellAuction.sold < _currentCellAuction.maxSellable,
            "auction finished"
        );
        require(
            block.timestamp > _currentCellAuction.startTime,
            "auction not start"
        );
        uint256 price = getCurrentVRGDAPrice();
        require(msg.value >= price, "Insufficient funds");
        uint256 tokenId = _currentCellAuction.startTokenID +
            _currentCellAuction.sold;

        _mint(msg.sender, tokenId);

        _currentCellAuction.sold++;
        _cellMintedNum++;

        uint256 randomNum = getRandomNumber();
        //Obtain a random number between 1 and 511
        CellGene storage cell = _cellPool[tokenId];
        cell.id = tokenId;
        cell.bornBlock = uint64(block.number);
        cell.bornTime = uint64(block.timestamp);
        cell.bitmap.setBucket(0, randomNum);
        uint32 cellCount = 0;

        for (uint256 i = 0; i < 9; i++) {
            if (cell.bitmap.get(i)) {
                cellCount += 1;
            }
        }
        cell.livingCellTotal = cellCount;

        if (msg.value > price) {
            (bool sent, ) = payable(msg.sender).call{value: msg.value - price}(
                ""
            ); // Returns false on failure
            require(sent, "failed to return Ether");
        }
    }

    //Obtain 512 unique random numbers for 10 rounds
    function getRandomNumber() public returns (uint256) {
        uint256 randomNumber = uint256(
            keccak256(abi.encodePacked(block.timestamp, msg.sender))
        );
        for (uint256 i = 0; i < MAX_RANDOM_NUM; i++) {
            uint256 index = (randomNumber + i) % MAX_RANDOM_NUM;
            if (!_randomBitmap.get(index)) {
                _randomBitmap.set(index);
                return index + 1;
            }
        }

        _randomBitmap.unsetBucket(0, 0);
        _randomBitmap.unsetBucket(1, 0);
        _current_round_number += 1;
        return getRandomNumber();
    }

    //Get Cellula information
    function getLifeGene(
        uint256 tokenID
    )
        public
        view
        returns (
            string memory genes,
            uint256 bornBlock,
            uint256 livingCellTotal,
            uint64 bornTime, 
            uint64 rentedCount,
            uint256 bornPrice
        )
    {
        CellGene storage cell = _cellPool[tokenID];
        bornBlock = cell.bornBlock;
        livingCellTotal = cell.livingCellTotal;
        genes = getGenesSequence(tokenID);
        bornTime=cell.bornTime;
        rentedCount=cell.rentedCount;
        bornPrice=cell.bornPrice;
    }

 

    function getRLESting(
        uint256 tokenId
    ) public view returns (string memory rleSting) {
        string memory rle = decodeGenes(tokenId);
        rleSting = string(
            abi.encodePacked(
                "x = ",
                Strings.toString(3),
                ", y = ",
                Strings.toString(3),
                "\n",
                rle
            )
        );
    }

    //Serialize and display gene information
    function getGenesSequence(
        uint256 tokenID
    ) public view returns (string memory genes) {
        CellGene storage cell = _cellPool[tokenID];
        string memory result;
        uint256 count = 3 * 3;
        for (uint256 i = count; i > 0; i--) {
            bool value = cell.bitmap.get(i - 1);
            if (value) {
                result = string(abi.encodePacked(result, "1"));
            } else {
                result = string(abi.encodePacked(result, "0"));
            }
        }

        return result;
    }

    function decodeGenes(
        uint256 tokenId
    ) internal view returns (string memory) {
        // Convert the bitmap to a 2D array

        CellGene storage cell = _cellPool[tokenId];
        uint256 width = 3;
        uint256 height = 3;

        uint256[][] memory pixels = new uint256[][](height);
        for (uint256 i = 0; i < height; i++) {
            pixels[i] = new uint256[](width);
            for (uint256 j = 0; j < width; j++) {
                pixels[i][j] = cell.bitmap.get(
                    width * height - (i * width + j) - 1
                )
                    ? 1
                    : 0;
            }
        }

        // Initialize an empty RLE string
        string memory rle = "";

        for (uint256 i = 0; i < height; i++) {
            uint256 runValue = pixels[i][0];
            uint256 runLength = 0;

            for (uint256 j = 0; j < width; j++) {
                uint256 pixelValue = pixels[i][j];

                if (pixelValue == runValue) {
                    runLength++;
                } else {
                    rle = string(
                        abi.encodePacked(
                            rle,
                            Strings.toString(runLength),
                            runValue == 1 ? "o" : "b"
                        )
                    );
                    runValue = pixelValue;
                    runLength = 1;
                }
            }
            rle = string(
                abi.encodePacked(
                    rle,
                    Strings.toString(runLength),
                    runValue == 1 ? "o" : "b",
                    "$"
                )
            );
        }

        return rle;
    }

    function getEvolutionaryAlgebra(
        uint256 tokenId
    ) public view returns (uint256) {
        uint256 mintBlockNum = _cellPool[tokenId].bornBlock;
        uint256 algebra = ((block.number - mintBlockNum) * BLOCK_TIME) /
            EVOLUTION_TIME;
        return algebra;
    }

    function lifeBaseRules(
        uint8[9] calldata cellGenes
    ) public pure returns (uint8) {
        uint8 liveCellNum = 0;

        for (uint256 i = 0; i < 9; i++) {
            if ((i != 4) && (cellGenes[i] == 1)) {
                liveCellNum += 1;
            }
        }
        if (liveCellNum == 2) {
            return cellGenes[4];
        }
        return liveCellNum <= 1 || liveCellNum >= 4 ? 0 : 1;
    }

    /* tools */
    receive() external payable {}

    function changeBaseURL(string calldata newBaseURL) public onlyOwner {
        _baseUrl = newBaseURL;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseUrl;
    }

    function isCenterCellAlive(
        uint8[9] memory cells
    ) public pure returns (bool) {
        // Convert a one-dimensional array to a two-dimensional state matrix
        bool[3][3] memory matrix = [
            [false, false, false],
            [false, false, false],
            [false, false, false]
        ];
        for (uint256 i = 0; i < cells.length; i++) {
            matrix[i / 3][i % 3] = cells[i] == 1;
        }

        // Get the coordinates of the center cell
        uint8 centerX = 1;
        uint8 centerY = 1;

        // Calculate the state of the cells surrounding the center cell
        uint8 aliveCount = 0;
        for (uint8 i = 0; i < 3; i++) {
            for (uint8 j = 0; j < 3; j++) {
                if (i == centerX && j == centerY) {
                    continue;
                }
                if (matrix[i][j]) {
                    aliveCount++;
                }
            }
        }

        // Calculate the state of the center cell according to the rules of the Game of Life
        if (matrix[centerX][centerY]) {
            if (aliveCount == 2 || aliveCount == 3) {
                return true;
            } else {
                return false;
            }
        } else {
            if (aliveCount == 3) {
                return true;
            } else {
                return false;
            }
        }
    }
}
