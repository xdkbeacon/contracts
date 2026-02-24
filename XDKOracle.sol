// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import {IPancakePair} from "./IPancakePair.sol";
import {IUniswapV2Factory} from "./IUniswapV2Factory.sol";
import {IPancakeRouter02} from "./IPancakeRouter02.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {_GPC, _ROUTER, _WBNB, _USDC, _USDT, DEAD_WALLET} from "./Const.sol";

contract XDKOracle is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    modifier onlyEOA() {
        require(tx.origin == msg.sender, "EOA");
        _;
    }

    IPancakeRouter02 public uniswapV2Router;
    address public xdk;
    address public uniswapV2Pair;
    IPancakePair internal uniswapV2PairGpc;
    IPancakePair internal uniswapV2PairUsdt;

    // ========== 核心配置（可根据业务调整） ==========
    // 循环数组最大容量（比如存储1440个价格点，每60秒一个，覆盖24小时）
    uint256 public constant MAX_CAPACITY = 1440;
    // 价格更新的最小时间间隔（防止高频更新，单位：秒）
    uint256 public constant MIN_UPDATE_INTERVAL = 60; // 秒

    uint256 public constant DOWN_LINE = 20;

    uint256 public constant LENGTH = 100;

    // ========== 循环数组存储 ==========
    // 存储价格点：价格（wei）+ 时间戳（uint256）
    struct PricePoint {
        uint256 price; // 代币价格（如USDT/ETH的价格，单位wei）
        uint256 timestamp; // 价格采集时间戳
    }

    // 固定长度循环数组（替代动态数组，Gas更优）
    PricePoint[MAX_CAPACITY] private _priceQueue;
    uint256 private _head; // 队头索引（指向最旧数据）
    uint256 private _tail; // 队尾索引（指向最新数据的下一个位置）
    uint256 private _count; // 当前队列中的有效价格点数
    uint256 private _lastUpdateTime; // 上一次价格更新时间（防高频更新）

    function initialize(address _xdk_) public initializer {
        uniswapV2Router = IPancakeRouter02(_ROUTER);
        xdk = _xdk_;
        address factory = uniswapV2Router.factory();
        uniswapV2PairGpc = IPancakePair(
            IUniswapV2Factory(factory).getPair(_GPC, uniswapV2Router.WETH())
        );
        uniswapV2PairUsdt = IPancakePair(
            IUniswapV2Factory(factory).getPair(_USDT, uniswapV2Router.WETH())
        );
        uniswapV2Pair = IUniswapV2Factory(factory).getPair(
            _xdk_,
            _GPC
        );
        __Ownable_init();
        __ReentrancyGuard_init(); // 初始化父合约
    }

    function getGpcReserves()
        internal
        view
        virtual
        returns (uint256, uint256, uint256, uint256)
    {
        (uint256 _gpcBnbAmount, uint256 _gpcAmount, ) = uniswapV2PairGpc
            .getReserves();
        (uint256 _usdtAmount, uint256 _usdtBnbAmount, ) = uniswapV2PairUsdt
            .getReserves();
        return (_gpcBnbAmount, _gpcAmount, _usdtAmount, _usdtBnbAmount);
    }

    function gpcPrice() public view virtual returns (uint256) {
        (
            uint256 _gpcBnbAmount,
            uint256 _gpcAmount,
            uint256 _usdtAmount,
            uint256 _usdtBnbAmount
        ) = getGpcReserves();
        if (_gpcAmount == 0 || _usdtBnbAmount == 0) return 0;

        uint256 numerator = _gpcBnbAmount * _usdtAmount * 1e18;
        uint256 denominator = _gpcAmount * _usdtBnbAmount;
        return numerator / denominator;
    }

    function bnbPrice()public view virtual returns (uint256) {
          (uint256 _usdtAmount, uint256 _usdtBnbAmount, ) = uniswapV2PairUsdt
            .getReserves();
        return _usdtAmount * 1e18/_usdtBnbAmount;
    }

    function genPrice() public virtual onlyEOA {
        if (block.timestamp - _lastUpdateTime <= MIN_UPDATE_INTERVAL) {
            return;
        }
        uint256 _price_ = xdkPriceInner();
        // 3. 循环数组逻辑：添加新数据
        _priceQueue[_tail] = PricePoint({
            price: _price_,
            timestamp: block.timestamp
        });

        // 4. 更新尾指针（取模实现循环）
        _tail = (_tail + 1) % MAX_CAPACITY;

        // 5. 若队列已满，更新头指针（覆盖最旧数据）
        if (_count == MAX_CAPACITY) {
            _head = (_head + 1) % MAX_CAPACITY;
        } else {
            // 队列未满，增加计数
            _count += 1;
        }

        // 6. 更新最后更新时间
        _lastUpdateTime = block.timestamp;
    }

    function xdkPriceInner() internal view virtual returns (uint256) {
        IPancakePair pair = IPancakePair(uniswapV2Pair);
        address tokenA = pair.token0();
        uint256 gpcAmount;
        uint256 xdkAmount;
        (uint256 amountA, uint256 amountB, ) = pair.getReserves();
        if (tokenA == _GPC) {
            gpcAmount = amountA;
            xdkAmount = amountB;
        } else {
            gpcAmount = amountB;
            xdkAmount = amountA;
        }
        if (gpcAmount == 0) {
            return 0;
        }
        if (xdkAmount == 0) {
            return 0;
        }
        uint256 _price_ = (gpcAmount * gpcPrice()) / xdkAmount;
        return _price_;
    }

    /**
     * @dev 计算指定时长内的TWAP（时间加权平均价格）
     * @param duration 计算时长（单位：秒，如3600=1小时）
     * @return twap 时间加权平均价格（单位：wei）
     */
    /**
     * @dev 计算指定时长内的TWAP（时间加权平均价格）- 修复采样逻辑版
     * @param duration 计算时长（单位：秒，如3600=1小时）
     * @return twap 时间加权平均价格（单位：wei）
     */
    function calculateTWAP(
        uint256 duration
    ) internal view virtual returns (uint256 twap) {
        // ========== 1. 前置边界校验（杜绝无效计算） ==========
        if (_count == 0 || duration == 0) return 0;

        uint256 endTime = block.timestamp;
        uint256 startTime = endTime > duration ? endTime - duration : 0;

        // 价格点队列是时间递增的（head=最旧，tail=最新），核心变量初始化
        uint256 totalWeightedPrice; // 总加权价格
        uint256 totalWeight; // 总时间权重
        uint256 currentIdx = _head; // 遍历起始索引（最旧数据）
        uint256 traversedCount = 0; // 【改动1：新增遍历计数，解决满缓冲区遍历问题】

        // ========== 2. 第一步：跳过所有 < startTime 的无效价格点（批量跳过，而非逐次判断） ==========
        // 循环条件：当前点时间 < startTime 且未遍历完所有点
        // ========== 2. 第一步：跳过所有 < startTime 的无效价格点（批量跳过，而非逐次判断） ==========
        // 【改动2：替换终止条件为 traversedCount < _count，兼容满缓冲区】
        while (
            traversedCount < _count &&
            _priceQueue[currentIdx].timestamp < startTime
        ) {
            currentIdx = (currentIdx + 1) % MAX_CAPACITY;
            traversedCount++; // 【改动3：遍历计数+1】
        }

        // ========== 3. 第二步：仅计算 [startTime, endTime] 范围内的价格点（找到边界立即终止） ==========
        // 记录上一个价格点的时间戳（用于计算权重）
        uint256 prevTimestamp = startTime;
        // 遍历条件：未遍历完所有点 + 当前点时间 <= endTime
        while (
            traversedCount < _count &&
            _priceQueue[currentIdx].timestamp <= endTime
        ) {
            PricePoint storage point = _priceQueue[currentIdx];

            // 计算当前价格点的时间权重：当前点时间 - 上一个点时间（确保权重在[startTime, endTime]内）
            uint256 weight = point.timestamp - prevTimestamp;
            // 过滤无效权重（避免0值累加）
            if (weight > 0) {
                unchecked {
                    totalWeightedPrice += point.price * weight;
                    totalWeight += weight;
                }
            }

            // 更新上一个时间戳为当前点时间，移动到下一个点
            prevTimestamp = point.timestamp;
            currentIdx = (currentIdx + 1) % MAX_CAPACITY;
            traversedCount++; // 【改动5：遍历计数+1】
        }

        // ========== 4. 第三步：处理最后一个价格点到endTime的权重 ==========
        // 若有有效价格点，补充最后一个点到endTime的权重
        if (totalWeight > 0 && prevTimestamp < endTime) {
            uint256 lastWeight = endTime - prevTimestamp;
            if (lastWeight > 0) {
                // 最后一个价格点的索引：currentIdx的前一个（因为上面循环已移动）
                // 【改动6：统一取模计算lastIdx，解决下溢风险】
                uint256 lastIdx = (currentIdx + MAX_CAPACITY - 1) %
                    MAX_CAPACITY;
                unchecked {
                    totalWeightedPrice +=
                        _priceQueue[lastIdx].price *
                        lastWeight;
                    totalWeight += lastWeight;
                }
            }
        }

        // ========== 5. 计算最终TWAP（兜底逻辑） ==========
        if (totalWeight == 0) {
            // 无有效价格点时，返回最新价格
            uint256 latestIdx = (_tail + MAX_CAPACITY - 1) % MAX_CAPACITY;
            twap = _priceQueue[latestIdx].price;
        } else {
            unchecked {
                twap = totalWeightedPrice / totalWeight;
            }
        }

        return twap;
    }

    function price() external view virtual returns (uint256) {
        return priceTime(6 hours);
    }

    function priceTime(uint256 time) public view virtual returns (uint256) {
        uint256 _price_ = calculateTWAP(time);
        if (_price_ == 0) {
            uint256 latestIdx = _tail == 0 ? MAX_CAPACITY - 1 : _tail - 1;
            _price_ = _priceQueue[latestIdx].price;
            if (_price_ == 0) _price_ = xdkPriceInner();
        }
        return _price_;
    }
    receive() external payable {
        
    }

      // 或者完全不实现 receive，依赖 fallback
    fallback() external payable {
        // 空实现，仅接收 BNB
        
    }


    uint256[255] private __gap;
}
