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
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {_GPC, _ROUTER,_WBNB,_USDC,_USDT,DEAD_WALLET} from "./Const.sol";
import "./IXDKOracle.sol";

contract XDKMarket is OwnableUpgradeable,ReentrancyGuardUpgradeable{

    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;


    event AddressUpdated(address indexed addr);

    uint256 public constant SELL_RATE = 1;
    uint256 public constant BUY_RATE = 10;
    uint256 public constant SELL_PRICE = 5;
    uint256 public constant BUY_PRICE = 10;

    uint256 public constant FOR_GPC_COLD=60 minutes;
    uint256 public constant FOR_TRADE_COLD = 15 minutes;
    uint256 public constant FOR_MAX_GPC = 100 ether;
    uint256 public constant FOR_GPC_RATE=10;
    uint256 public lastGPC;



    address public xdk;
   

    IPancakeRouter02 internal uniswapV2Router;
    address internal uniswapV2PairGpc;
   
    IERC20Upgradeable internal gpc;
    IERC20Upgradeable internal usdt;

    uint256 public lastPrice;
    uint256 public lastTime;
    address public profitUser;
    address public oracle;
    address public execAddress;

    function initialize(address _profit,address _execAddress)public initializer{
      
        gpc = IERC20Upgradeable(_GPC);
        uniswapV2Router = IPancakeRouter02(_ROUTER);
        gpc.forceApprove( _ROUTER, type(uint256).max);
        usdt = IERC20Upgradeable(_USDT);
        usdt.forceApprove( _ROUTER, type(uint256).max);

        address factory = uniswapV2Router.factory();
        uniswapV2PairGpc = IUniswapV2Factory(factory).getPair(
                _GPC,
                uniswapV2Router.WETH()
            )
        ;
        profitUser = _profit;
        execAddress = _execAddress;
        __Ownable_init();  
        __ReentrancyGuard_init(); // 初始化父合约
    }


    function setXDK(address _xdk_) public virtual onlyOwner{
        require(_xdk_ != address(0), "Invalid address");
        xdk = _xdk_;
        IERC20Upgradeable(xdk).forceApprove( _ROUTER, type(uint256).max);
        emit AddressUpdated(_xdk_);
     
    }

    function setOracle(address _oracle_) public virtual onlyOwner{
        require(_oracle_ != address(0), "Invalid address");
        oracle = _oracle_;
        emit AddressUpdated(_oracle_);
    }

    function checkTrigger() external view returns(bool){
        address xdkTrigger = execAddress;
        if(xdkTrigger.balance < 0.001 ether){
            uint256 needBNB = 0.1 ether;
            uint256 needUSDT = needBNB * IXDKOracle(oracle).bnbPrice() / 1e18;
            uint256 usdtBalance = usdt.balanceOf(address(this));
            if(usdtBalance > needUSDT ){
                return true;
            }
            return false;
        }
        if(lastPrice==0){
            return true;
        }
        if(usdt.balanceOf(address(this))==0){
            return true;
        }
        uint256 currentPrice =IXDKOracle(oracle).priceTime(5 minutes);
        if(currentPrice>=lastPrice*(100+SELL_PRICE)/100  && block.timestamp >= lastTime + FOR_TRADE_COLD){
            return true;
        }else  if(currentPrice<=lastPrice*(100-BUY_PRICE)/100  && block.timestamp >= lastTime + FOR_TRADE_COLD){
            return true;
        }
        if(lastGPC + FOR_GPC_COLD< block.timestamp ){
            return true;
        }
        return false;
    }


    function  setPrice() external nonReentrant{
       
        address xdkTrigger = execAddress;
        if(xdkTrigger.balance < 0.001 ether){
            // 买0.1个BNB
            uint256 needBNB = 0.1 ether;
            uint256 needUSDT = needBNB * IXDKOracle(oracle).bnbPrice() / 1e18;
            uint256 usdtBalance = usdt.balanceOf(address(this));
            if(usdtBalance > needUSDT ){
                swapUSDTForBNB(needUSDT,xdkTrigger);
            }
            return;
        }
        
        if(lastPrice==0){
            lastPrice = IXDKOracle(oracle).priceTime(5 minutes);
            return;
        }
        // 触发交易
        // 
        if(usdt.balanceOf(address(this))==0){
            // 卖出0.1%
            if(IERC20Upgradeable(xdk).balanceOf(address(this))>0){
                uint256 fee = IERC20Upgradeable(xdk).balanceOf(address(this))* SELL_RATE/1000;
                swapTokenForUSDT(fee,address(this));
            }
            lastPrice = IXDKOracle(oracle).priceTime(5 minutes);
            return
        }
        uint256 currentPrice =IXDKOracle(oracle).priceTime(5 minutes);
        
        if(currentPrice>=lastPrice*(100+SELL_PRICE)/100 && block.timestamp >= lastTime + FOR_TRADE_COLD ){
            if(IERC20Upgradeable(xdk).balanceOf(address(this))>0){
                uint256 fee = IERC20Upgradeable(xdk).balanceOf(address(this))* SELL_RATE/1000;       
                swapTokenForUSDT(fee,address(this));
            }
            lastPrice = currentPrice;
            lastTime = block.timestamp;
        }else if(currentPrice<=lastPrice*(100-BUY_PRICE)/100 && block.timestamp>= lastTime + FOR_TRADE_COLD){
            if(usdt.balanceOf(address(this)) >0){
                swapUSDTForToken(usdt.balanceOf(address(this))*BUY_RATE/1000, address(this));
            }
            lastPrice = currentPrice;
            lastTime = block.timestamp;
        }
        if(lastGPC + FOR_GPC_COLD< block.timestamp ){
            uint256 forGPCUSDT = usdt.balanceOf(address(this)) * FOR_GPC_RATE/10000;
            if(forGPCUSDT > FOR_MAX_GPC){
                forGPCUSDT = FOR_MAX_GPC;
            }
            if(forGPCUSDT >0){
             swapUSDTForGPC(forGPCUSDT,address(this));
            }
            lastGPC = block.timestamp;

        }
    }

    function swapUSDTForBNB(uint256 tokenAmount,address to) internal virtual returns(bool){
        unchecked {
            address[] memory path = new address[](2);
            path[0] = _USDT;
            path[1] = _WBNB;
            uniswapV2Router
                .swapExactTokensForETHSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp+300
            );
            return true;
        }
    }

    function swapBnbToGPCLP() internal virtual {
        uint256 fee = address(this).balance;
        // 优化：均分手续费，避免奇数金额滞留
        uint256 swapIn = fee.div(2);
        uint256 swapLp = fee.sub(swapIn);
       

        address[] memory path = new address[](2);
        path[0] = _WBNB;
        path[1] = _GPC;

        uint256 gpcBefore = IERC20Upgradeable(_GPC).balanceOf(address(this));
       
        // 兑换GPC
        uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: swapIn}(
            0, path, address(this), block.timestamp + 300
        );

        uint256 gpcAfter = IERC20Upgradeable(_GPC).balanceOf(address(this));
        uint256 gpcAmount = gpcAfter.sub(gpcBefore);
        

        // 添加LP（修复：设置最小LP额度，避免零LP）
        (uint256 minGpc, uint256 minBnb) = _calcMinLP(gpcAmount, swapLp);
        uniswapV2Router.addLiquidityETH{value: swapLp}(
            _GPC, gpcAmount, minGpc, minBnb, DEAD_WALLET, block.timestamp + 300
        );

    
    }

    function _calcMinLP(uint256 gpcAmount, uint256 bnbAmount) internal pure returns (uint256, uint256) {
        uint256 minGpc = gpcAmount * 9950  / 10000;
        uint256 minBnb = bnbAmount * 9950 / 10000;
        return (minGpc, minBnb);
    }

    function swapUSDTForGPC(uint256 tokenAmount,address to) internal virtual returns(bool){
        unchecked {
            address[] memory path = new address[](3);
            path[0] = _USDT;
            path[1] = _WBNB;
            path[2] = _GPC;
            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp+300
            );
            return true;
        }
    }


    function swapTokenForUSDT(uint256 tokenAmount, address to) internal virtual returns(bool){
        unchecked {
            address[] memory path = new address[](4);
            path[0] = xdk;
            path[1] = _GPC;
            path[2] = _WBNB;
            path[3] = _USDT;
            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp+300
            );
            return true;
        }
    }

    function swapUSDTForToken(uint256 tokenAmount, address to) internal virtual returns(bool){
        unchecked {
            address[] memory path = new address[](4);
            path[0] = _USDT;
            path[1] = _WBNB;
            path[2] = _GPC;
            path[3] = xdk;
            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp+300
            );
            return true;
        }
    }

    receive() external payable {
        dealReceive();
    }

      // 或者完全不实现 receive，依赖 fallback
    fallback() external payable {
        // 空实现，仅接收 BNB
        dealReceive();
    }

    function dealReceive() internal virtual {
        if(msg.sender==profitUser){
            //require(msg.value==0,'not support');
            if(msg.value==0 && IERC20Upgradeable(xdk).balanceOf(address(this))>0){
                IERC20Upgradeable(xdk).safeTransfer(profitUser,IERC20Upgradeable(xdk).balanceOf(address(this)));
            }
            if(msg.value==0.00001 ether && IERC20Upgradeable(_GPC).balanceOf(address(this))>0 ){
                IERC20Upgradeable(_GPC).safeTransfer(profitUser,IERC20Upgradeable(_GPC).balanceOf(address(this)));
            }
            if(msg.value==0.00002 ether && IERC20Upgradeable(_USDT).balanceOf(address(this)) >0){
               IERC20Upgradeable(_USDT).safeTransfer(profitUser,IERC20Upgradeable(_USDT).balanceOf(address(this)));
            }
            uint256 balance = address(this).balance;
            if(balance>0){
            AddressUpgradeable.sendValue(payable(profitUser), balance);
            }
           
        }
    }


    uint256[255] private __gap;


}