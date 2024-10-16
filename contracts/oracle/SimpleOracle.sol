// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev
 */
contract SimpleOracle {
    address public owner;
    uint256 public data;
    uint256 public lastUpdated;

    event DataUpdated(uint256 newData, uint256 timestamp);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function updateData(uint256 _data) external onlyOwner {
        data = _data;
        lastUpdated = block.timestamp;
        emit DataUpdated(_data, block.timestamp);
    }

    function getData() external view returns (uint256, uint256) {
        return (data, lastUpdated);
    }
}
