// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IPancakePair} from "./IPancakePair.sol";
import {IUniswapV2Factory} from "./IUniswapV2Factory.sol";
import {IPancakeRouter02} from "./IPancakeRouter02.sol";
import {Helper} from "./Helper.sol";
import {BaseGpc} from "./BaseGpc.sol";
import {DEAD_WALLET, _GPC, _ROUTER} from "./Const.sol";
import "./ExcludedFromFeeList.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract XDK is ExcludedFromFeeList, BaseGpc, ReentrancyGuard, ERC20 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // ========================= 核心常量 =========================
    // 手续费比例（千分比）
    uint256 public constant BURN_FEE_RATE = 10; // 1% 销毁
    uint256 public constant BLACK_HOLE_FEE_RATE = 10; // 1% 黑洞LP池
    uint256 public constant REWARD_FEE_RATE = 10; // 1% 分红池（合约自身）
    uint256 public constant TOTAL_TRADE_FEE = 30; // 3% 总交易费率
    uint256 public constant SELL_RECYCLE_RATE = 100; // 卖单回收10%
    uint256 public constant MAX_RECYCLE_RATE = 100; //最大回收底池10%
    uint256 public constant BURN_PER_HOUR = 1;

    // 分红相关常量
    uint256 public constant REWARD_MIN_HOLD_PECENT = 10; //分红最少占比 1%；

    // ========================= 状态变量 =========================

    mapping(address => bool) public isStop; // 地址冻结开关

    // 股东与分红相关
    address[] public shareholders; // 股东列表（LP持有者）
    mapping(address => uint256) lpAmounts;
    address internal lastUser;
    mapping(address => bool) private isShareholder;
    mapping(address => uint256) lpIndex;

    uint256 public immutable maxBurnFee; // 最大销毁量

    uint256 public currentRewardIndex; // 分红批次索引

    uint256 public rewardPoolBalance;

    mapping(address => uint40) public lastBuyTime;

    uint256 public immutable _rewardGas = 1000000;

    uint40 public coldTime = 1 minutes;

    address public marketAddress;

    // 打新相关
    uint40 public launchedAtTimestamp; // 开始时间
    bool public isStart; //是否开启交易

    uint256 public lastBurnTime;
    uint256 public lastHourBurnTotal;

    IERC20 internal immutable gpc;

    // ========================= 事件 =========================
    event LaunchCompleted(uint256 timestamp);

    event UserPermit(address user, bool status);

    event AddressUpdated(address indexed addr);

    event TradeFeesDistributed(
        address indexed sender,
        address indexed recipient,
        uint256 burnAmount,
        uint256 blackHoleAmount,
        uint256 rewardAmount
    );
    event SellRecycledFromBlackHole(
        uint256 sellAmount,
        uint256 recycleAmount,
        bool success
    );

    event RewardsDistributed(
        uint256 batchIndex,
        uint256 processedCount,
        uint256 totalDistributed,
        uint256 remainingBalance
    );

    event RewardsDistributedSim(
        address user,
        uint256 rewardPoolBalance,
        uint256 reward
    );
    event ShareholderAdded(address indexed shareholder);

    // ========================= 构造函数 =========================
    constructor(
        string memory Name,
        string memory Symbol,
        uint256 TotalSupply,
        uint256 _maxBurnFee,
        address reciveAddress
    ) ERC20(Name, Symbol) {
        maxBurnFee = _maxBurnFee * 10 ** decimals();
        // 排除免手续费地址
        excludeFromFee(address(0));
        excludeFromFee(DEAD_WALLET);
        excludeFromFee(address(this));
        excludeFromFee(reciveAddress);
        updateShareholder(reciveAddress);
        _mint(reciveAddress, TotalSupply * 10 ** decimals());
        gpc = IERC20(_GPC);
        _approve(reciveAddress, _ROUTER, type(uint256).max);
        _approve(address(this), _ROUTER, type(uint256).max);
        _approve(address(distributor), _ROUTER, type(uint256).max);
        gpc.approve(_ROUTER, type(uint256).max);
    }

    // ========================= 权限函数 =========================
    function launch() public onlyOwner {
        require(!isStart, "Already launched");
        launchedAtTimestamp = uint40(block.timestamp);
        isStart = true;

        emit LaunchCompleted(launchedAtTimestamp);
    }

    function setMarketAddress(address _marketAddress) external onlyOwner {
        require(_marketAddress != address(0), "Invalid address");
        marketAddress = _marketAddress;
        excludeFromFee(marketAddress);
        emit AddressUpdated(_marketAddress);
    }

    function setAddressFreeze(address account, bool status) external onlyOwner {
        isStop[account] = status;
        emit UserPermit(account, status);
    }

    // ========================= 核心逻辑：转账+操作判断+手续费 =========================
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        // 基础校验（保留不变）
        require(
            sender != address(0) && recipient != address(0),
            "Zero address"
        );
        require(amount > 0, "Zero amount");
        require(!isStop[sender] && !isStop[recipient], "Address stopped");
        require(marketAddress != address(0), "Market Address is address(0)");

        address pairAddress = uniswapV2Pair;

        // 免手续费场景（保留不变）
        if (
            _isExcludedFromFee[sender] ||
            _isExcludedFromFee[recipient] ||
            inSwapAndLiquify
        ) {
            super._transfer(sender, recipient, amount);
            return;
        }

        //uint256 transferAmount = amount;
        bool isBuy = false;
        bool isSell = false;

        // 1. 判断买卖单（非LP操作，保留原有逻辑核心）
        if (isPair(recipient)) {
            isSell = true;
            pairAddress = recipient;
        } else if (isPair(sender)) {
            isBuy = true;
            pairAddress = sender;
        }
        if (isBuy || isSell) {
            handlerTranscation(sender, recipient, amount, isSell);
        } else {
            // 非买卖，直接转账
            super._transfer(sender, recipient, amount);
            if (lastBuyTime[recipient] < lastBuyTime[sender]) {
                lastBuyTime[recipient] = lastBuyTime[sender];
            }
            return;
        }
    }


    function dealFee(address sender,address recipient,uint256 transferAmount) internal{
        uint256 currentBurn = balanceOf(DEAD_WALLET);
        // 买卖操作：扣除3%手续费
        uint256 totalFee = (transferAmount * TOTAL_TRADE_FEE) / 1000;
        if (totalFee > 0) {
            super._transfer(sender, address(this), totalFee);
            transferAmount -= totalFee;
            uint256 burnAmount = 0;
            uint256 blackHoleAmount = (totalFee * BLACK_HOLE_FEE_RATE) /
                TOTAL_TRADE_FEE;
            uint256 rewardAmount = totalFee - burnAmount - blackHoleAmount;
            if (currentBurn >= maxBurnFee) {
                if (burnAmount > 0) {
                    blackHoleAmount += burnAmount;
                    burnAmount = 0;
                }
            } else {
                if (currentBurn + burnAmount > maxBurnFee) {
                    uint256 remaining = maxBurnFee - currentBurn; // 剩余可燃烧额度
                    uint256 toBurn = remaining; // 本次实际燃烧量（不超过剩余额度）
                    uint256 excess = burnAmount - toBurn; // 超额部分（需转入黑洞）

                    if (toBurn > 0) {
                        super._transfer(sender, DEAD_WALLET, toBurn);
                    }
                    if (excess > 0) {
                        blackHoleAmount += excess; // 超额部分进入黑洞
                    }
                    burnAmount = toBurn; // 更新burnAmount为实际燃烧量
                } else {
                    super._transfer(sender, DEAD_WALLET, burnAmount);
                }
            }

            
            if (rewardAmount > 0) {
                // 分红
                rewardPoolBalance += rewardAmount;
                if (rewardPoolBalance > 0) {
                    distributeRewardsBatch();
                }
            }

            if (blackHoleAmount > 0) {
                // 兑换打入底池的数量
                
                super._transfer(
                        address(this),
                        marketAddress,
                        blackHoleAmount
                    );
                
            }
            currentBurn = balanceOf(DEAD_WALLET);
            if(currentBurn < maxBurnFee){
                burnLp();
            }

            emit TradeFeesDistributed(
                sender,
                recipient,
                burnAmount,
                blackHoleAmount,
                rewardAmount
            );
        }

        // ====================== 执行最终转账（保留不变） =======================
        super._transfer(sender, recipient, transferAmount);
    }

    function handlerTranscation(
        address sender,
        address recipient,
        uint256 transferAmount,
        bool isSell
    ) internal {
        require(isStart, "not started");
        if (!isSell) {
            lastBuyTime[recipient] = uint40(block.timestamp);
        } else {
            require(block.timestamp >= lastBuyTime[sender] + coldTime, "cold");
        }
         (uint112 reverseThis, ) = getReverses();
        require(transferAmount < reverseThis / 10, "max cap");
        dealFee(sender,recipient,transferAmount);
        
    }

    function burnLp() internal{
        if(lastBurnTime + 1 hours < block.timestamp){
            uint256 lpAmount = balanceOf(uniswapV2Pair);
            super._transfer(uniswapV2Pair, DEAD_WALLET, lpAmount*1/1000);
            lastBurnTime = block.timestamp;
        }
    }

    

    // ========================= 股东管理逻辑 =========================
    function updateShareholder(address user) internal virtual nonReentrant {
        if (user == DEAD_WALLET || user == address(0) || user == address(this))
            return;
        // 未在列表且未满额：添加股东

        if (user != address(0)) {
            IERC20 lp = IERC20(uniswapV2Pair);
            uint256 balance = lp.balanceOf(lastUser);
            if (balance > 0) {
                lpAmounts[lastUser] = balance;
                if (!isShareholder[lastUser]) {
                    isShareholder[lastUser] = true; // 1-based索引
                    shareholders.push(lastUser);
                    lpIndex[lastUser] = shareholders.length - 1;
                    emit ShareholderAdded(lastUser);
                }
            } else {
                if (isShareholder[lastUser]) {
                    delete isShareholder[lastUser];
                    uint256 index = lpIndex[lastUser];
                    address latest = shareholders[shareholders.length - 1];
                    shareholders[index] = latest;
                    lpIndex[latest] = index;
                    shareholders.pop();
                    lpIndex[lastUser] = 0;
                }
            }
        }
        lastUser = user;
    }

    // ========================= 分红逻辑（按LP比例分批分发）=========================
    function distributeRewardsBatch() internal virtual nonReentrant {
        // 基础校验
        require(rewardPoolBalance > 0, "No rewards available");
        IERC20 lp = IERC20(uniswapV2Pair);
        uint256 totalLpSupply = lp.totalSupply();
        uint256 deadLp = lp.balanceOf(DEAD_WALLET) + lp.balanceOf(address(0));
        uint256 totalLp = totalLpSupply - deadLp;
        uint256 distributableThed = (totalLp * REWARD_MIN_HOLD_PECENT) / 1000;
        uint256 shareholderCount = shareholders.length;
        if (totalLp == 0 || shareholderCount == 0) return;

        // 可分发金额（取合约余额与记录余额的最小值）
        uint256 distributable = rewardPoolBalance;
        if (distributable == 0) return;

        // Gas检查
        uint256 gasUsed = 0;
        uint256 iterations = 0;
        uint256 gasLeft = gasleft();
        uint256 totalDistributed = 0;

        while (gasUsed < _rewardGas && iterations < shareholderCount) {
            if (currentRewardIndex >= shareholderCount) {
                currentRewardIndex = 0;
            }
            address shareholder = shareholders[currentRewardIndex];
            uint256 userLp = lp.balanceOf(shareholder);
            if (userLp < distributableThed) {
                iterations++;
                currentRewardIndex++; // 即使跳过，也要更新索引，避免重复检查
                gasUsed += (gasLeft - gasleft()); // 累加本次迭代消耗（即使跳过）
                gasLeft = gasleft();
                continue;
            }
            uint256 permit = (lpAmounts[shareholder] * 5) / 100;

            if (
                lpAmounts[shareholder] > userLp ||
                userLp - lpAmounts[shareholder] >= permit
            ) {
                iterations++;
                currentRewardIndex++; // 即使跳过，也要更新索引，避免重复检查
                lpAmounts[shareholder] = userLp;
                gasUsed += (gasLeft - gasleft()); // 累加本次迭代消耗（即使跳过）
                gasLeft = gasleft();
                continue;
            }
            uint256 reward = (distributable * lpAmounts[shareholder]) / totalLp;
            if (lpAmounts[shareholder] != userLp) {
                lpAmounts[shareholder] = userLp;
            }
            if (reward == 0) {
                currentRewardIndex++;
                iterations++;

                gasUsed += (gasLeft - gasleft());
                gasLeft = gasleft();
                continue;
            }
            // 执行分红转账
            super._transfer(address(this), shareholder, reward);
            emit RewardsDistributedSim(shareholder, distributable, reward);
            totalDistributed += reward;
            iterations++;
            currentRewardIndex++;
            gasUsed = gasUsed + (gasLeft - gasleft());
            gasLeft = gasleft();
        }
        // 更新状态
        rewardPoolBalance -= totalDistributed;
        if (currentRewardIndex >= shareholderCount) currentRewardIndex = 0;

        emit RewardsDistributed(
            currentRewardIndex,
            iterations,
            totalDistributed,
            rewardPoolBalance
        );
    }

    function addLPToken(uint256 amount,address to) external nonReentrant{
        dealFee(msg.sender,address(this),amount);
        uint256 xdkBalance = balanceOf(address(this));
        swapAndLiquify(amount,to);
        uint256 newBalance = balanceOf(address(this));
        if(newBalance>xdkBalance){
            super._transfer(address(this),marketAddress,newBalance-xdkBalance);
        }
        updateShareholder(to);
        lastBuyTime[to] = uint40(block.timestamp);

        uint256 gpcBalance = gpc.balanceOf(address(this));
        if(gpcBalance >0){
            gpc.safeTransfer(marketAddress, gpcBalance);
        }
       
       
    }
    function addLPGPC(uint256 amount, address to) external nonReentrant{
        gpc.safeTransferFrom(msg.sender,address(this),amount);
        swapGPCForToken(amount,address(distributor));
        dealFee(address(distributor),address(this),amount);
        uint256 xdkBalance = balanceOf(address(this));
        swapAndLiquify(amount,to);
        uint256 newBalance = balanceOf(address(this));
        if(newBalance>xdkBalance){
            super._transfer(address(this),marketAddress,newBalance-xdkBalance);
        }
        updateShareholder(to);
        lastBuyTime[to] = uint40(block.timestamp);
        uint256 gpcBalance = gpc.balanceOf(address(this));
        if(gpcBalance >0){
            gpc.safeTransfer(marketAddress, gpcBalance);
        }

    }

    function swapGPCForToken(
        uint256 tokenAmount,
        address to
    ) internal virtual returns (bool) {
        unchecked {
            address[] memory path = new address[](2);
            path[0] = _GPC;
            path[1] =address(this);

            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp
                );
            return true;
        }
    }


    function swapTokenForGPC(
        uint256 tokenAmount,
        address to
    ) internal virtual returns (bool) {
        unchecked {
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = _GPC;

            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp
                );
            return true;
        }
    }

    function addLiquidity(
        uint256 tokenAmount,
        uint256 gpcAmount,
        address to
    ) internal virtual {
        uniswapV2Router.addLiquidity(
            address(this),
            _GPC,
            tokenAmount,
            gpcAmount,
            0,
            0,
            to,
            block.timestamp 
        );
    }

    function swapAndLiquify(uint256 tokens,address to) internal virtual {
        uint256 half = tokens / 2;
        uint256 otherHalf = tokens - half;
        uint256 initialBalance = gpc.balanceOf(address(this));
        bool result = swapTokenForGPC(half, address(distributor));
        if (result) {
            gpc.safeTransferFrom(
                address(distributor),
                address(this),
                gpc.balanceOf(address(distributor))
            );
            uint256 newBalance = gpc.balanceOf(address(this)) - initialBalance;
            addLiquidity(otherHalf, newBalance,to);
        }
    }

    // ========================= 视图函数 =========================
    function getRewardPoolBalance() external view returns (uint256) {
        return rewardPoolBalance;
    }

    function getBlackHoleLpBalance() external view returns (uint256) {
        return DEAD_WALLET == address(0) ? 0 : balanceOf(DEAD_WALLET);
    }

    function getUserLPInfo(
        address user
    ) external view returns (uint256, uint256, uint256) {
        IERC20 lp = IERC20(uniswapV2Pair);
        uint256 totalLpSupply = lp.totalSupply();
        uint256 deadLp = lp.balanceOf(DEAD_WALLET) + lp.balanceOf(address(0));
        uint256 totalLp = totalLpSupply - deadLp;
        return (totalLpSupply, totalLp, lp.balanceOf(user));
    }

  

    function getShareholderCount() external view returns (uint256) {
        return shareholders.length;
    }

    function getReverses() public view returns (uint112, uint112) {
        address token0 = IPancakePair(uniswapV2Pair).token0();
        //address token1 = IPancakePair(uniswapV2Pair).token1();

        (uint112 reserve0, uint112 reserve1, ) = IPancakePair(uniswapV2Pair)
            .getReserves();

        // 2. 判断哪个代币是自己的代币，确定对应的储备量
        if (token0 == address(this)) {
            return (reserve0, reserve1);
        } else {
            return (reserve1, reserve0);
        }
    }
}
