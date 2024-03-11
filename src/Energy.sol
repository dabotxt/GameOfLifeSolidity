// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract Energy {

    event ClaimEnergy(address account, uint256 claimTime);

    function sendClaimEnergyRequest(address account) public {
        uint256 claimTime = block.timestamp;
        emit ClaimEnergy(msg.sender, claimTime);
    }

}