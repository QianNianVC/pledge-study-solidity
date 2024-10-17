# pledge-study-solidity

---

# 项目开发
## 辅助合约
### 1. 多签
### 2. Uniswap v2
### 3. Oracle

## PledgePool.sol -- 核心合约
### 1. 涉及角色
* 借款人 Lend
* 贷款人 Borrow

### 2. 个人操作
* 存入
* 领取
* 提取

### 3. 池操作
* 初始化 
* 结算
* 完成
* 清算（前提：达到清算阈值）
* 结束

### 4. 零散知识点
4.1 为什么借款贷款获取 池基本信息和数据信息时，使用storage
```solidity
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
```
> 1. 合约的状态白能量，必须使用storage让其在合约的生命周期中持久化。
> 2. 节省gas（大结构体改变其中的数据）
 


# 小结（v1版本）
1. 理解质押与借贷组合的DeFi业务
2. 使用多签
3. 使用Uniswap获取实时代币之间的交换率（汇率）
4. 使用Oracle（价格语言机）

上述衍生
-- Oracle -> Chainlink

---



# 初次学习 pledge
在之前RCCStake项目学习质押的基础上，学习借贷业务。

# 初次接触
- uniswap
- oracle
- 借贷
- 多签