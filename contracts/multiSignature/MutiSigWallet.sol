// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
多签钱包的基本概念
    1. 参与者：多签钱包有多个参与者，每个参与者都有一个地址。
    2. 确认机制：需要一定数量的参与者（称为确认数）同意才能执行交易。
    3. 交易提案：参与者可以提出交易提案，其他参与者可以确认或拒绝。
    4. 执行交易：当交易获得足够的确认后，交易可以被执行。
*/
contract MultiSigWallet {
    address[] public owners;
    uint public requiredConfirmations;
    mapping(address => bool) public isOwner;
    mapping(uint => mapping(address => bool)) public confirmations;
    struct Transaction {
        address to;
        uint value;
        bytes data;
        bool executed;
    }
    Transaction[] public transactions;

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }

    modifier txExists(uint _txIndex) {
        require(_txIndex < transactions.length, "Transaction does not exist");
        _;
    }

    modifier notExecuted(uint _txIndex) {
        require(!transactions[_txIndex].executed, "Transaction already executed");
        _;
    }

    modifier notConfirmed(uint _txIndex) {
        require(!confirmations[_txIndex][msg.sender], "Transaction already confirmed");
        _;
    }

    /*构造函数：初始化合约时，设置所有者和所需的确认数。*/
    constructor(address[] memory _owners, uint _requiredConfirmations) {
        require(_owners.length > 0, "Owners required");
        require(_requiredConfirmations > 0 && _requiredConfirmations <= _owners.length, "Invalid number of required confirmations");

        for (uint i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "Invalid owner");
            require(!isOwner[owner], "Owner not unique");

            isOwner[owner] = true;
            owners.push(owner);
        }
        requiredConfirmations = _requiredConfirmations;
    }

    /*提交交易：所有者可以提交交易提案。*/
    function submitTransaction(address _to, uint _value, bytes memory _data) public onlyOwner {
        uint txIndex = transactions.length;
        transactions.push(Transaction({
            to: _to,
            value: _value,
            data: _data,
            executed: false
        }));
        emit SubmitTransaction(msg.sender, txIndex, _to, _value, _data);
    }

    /*确认交易：所有者可以确认交易。*/
    function confirmTransaction(uint _txIndex) public onlyOwner txExists(_txIndex) notExecuted(_txIndex) notConfirmed(_txIndex) {
        confirmations[_txIndex][msg.sender] = true;
        emit ConfirmTransaction(msg.sender, _txIndex);
    }

    /*执行交易：当交易获得足够的确认后，可以执行交易。*/
    function executeTransaction(uint _txIndex) public onlyOwner txExists(_txIndex) notExecuted(_txIndex) {
        require(getConfirmationCount(_txIndex) >= requiredConfirmations, "Cannot execute transaction");

        Transaction storage transaction = transactions[_txIndex];
        transaction.executed = true;

        (bool success, ) = transaction.to.call{value: transaction.value}(transaction.data);
        require(success, "Transaction failed");

        emit ExecuteTransaction(msg.sender, _txIndex);
    }

    function getConfirmationCount(uint _txIndex) public view returns (uint count) {
        for (uint i = 0; i < owners.length; i++) {
            if (confirmations[_txIndex][owners[i]]) {
                count += 1;
            }
        }
    }

    /*事件：用于记录交易的提交、确认和执行。*/
    event SubmitTransaction(address indexed owner, uint indexed txIndex, address indexed to, uint value, bytes data);
    event ConfirmTransaction(address indexed owner, uint indexed txIndex);
    event ExecuteTransaction(address indexed owner, uint indexed txIndex);
}