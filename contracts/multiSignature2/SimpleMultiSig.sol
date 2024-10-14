// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
使用 OpenZeppelin 构建多签钱包
如果你想使用 OpenZeppelin 的库来构建自己的多签钱包，你可以利用以下几个模块：
    1. AccessControl：用于管理合约的访问权限。
    2. Ownable：用于简单的所有权管理。
    3. ReentrancyGuard：用于防止重入攻击。
*/
contract SimpleMultiSig is AccessControl {
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    uint public requiredConfirmations;
    mapping(uint => mapping(address => bool)) public confirmations;

    struct Transaction {
        address to;
        uint value;
        bytes data;
        bool executed;
    }

    Transaction[] public transactions;

    constructor(address[] memory owners, uint _requiredConfirmations) {
        require(owners.length > 0, "Owners required");
        require(_requiredConfirmations > 0 && _requiredConfirmations <= owners.length, "Invalid number of required confirmations");

        for (uint i = 0; i < owners.length; i++) {
//            _setupRole(OWNER_ROLE, owners[i]);
            _setRoleAdmin(OWNER_ROLE, owners[i]);
        }
        requiredConfirmations = _requiredConfirmations;
    }

    function submitTransaction(address to, uint value, bytes memory data) public onlyRole(OWNER_ROLE) {
        uint txIndex = transactions.length;
        transactions.push(Transaction({
            to: to,
            value: value,
            data: data,
            executed: false
        }));
    }

    function confirmTransaction(uint txIndex) public onlyRole(OWNER_ROLE) {
        confirmations[txIndex][msg.sender] = true;
    }

    function executeTransaction(uint txIndex) public onlyRole(OWNER_ROLE) {
        require(getConfirmationCount(txIndex) >= requiredConfirmations, "Cannot execute transaction");

        Transaction storage transaction = transactions[txIndex];
        transaction.executed = true;

        (bool success,) = transaction.to.call{value: transaction.value}(transaction.data);
        require(success, "Transaction failed");
    }

    function getConfirmationCount(uint txIndex) public view returns (uint count) {
        for (uint i = 0; i < transactions.length; i++) {
            if (confirmations[txIndex][msg.sender]) {
                count += 1;
            }
        }
    }
}