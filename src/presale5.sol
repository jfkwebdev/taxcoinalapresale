//SPDX-License-Identifier-MIT

pragma solidity ^0.8.4;

import "solady/auth/Ownable.sol";
import "oz/utils/ReentrancyGuard.sol";

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function presaleDon(address recip, uint256 val) external returns(bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (
        uint amountToken,
        uint amountETH,
        uint liquidity
    );
    function WETH() external pure returns (address);
}

contract Presale is Ownable, ReentrancyGuard {

    error ps__out();
    error ps__alreadyClaimed();

    bool public isInit;
    bool public isDeposit;
    bool public isRefund;
    bool public isFinish;
    bool public burnTokens;
    address public creatorWallet;
    address public teamWallet;
    address public weth;
    uint8 constant private FEE = 14; //7% for the team 7% for cex
    uint8 public teamDrop;
    uint8 public tokenDecimals;
    uint256 public presaleTokens;
    uint256 public ethRaised;
    uint256 public coldTokenAmount;
    uint256 public coolTime1 = 2 hours; 
    uint256 public coolTime2 = 1 days;
    uint256 public coolTime3 = 7 days;
    uint64 public saleTime = uint64(90 hours); 

    struct Pool {
        uint64 startTime;
        uint64 endTime;
        uint8 liquidityPortion;
        uint256 saleRate;
        uint256 totalSupply;
        uint256 hardCap;
        uint256 softCap;
        uint256 maxBuy;
        uint256 minBuy;
    }

    IERC20 public tokenInstance;
    IUniswapV2Factory public immutable UniswapV2Factory;
    IUniswapV2Router02 public immutable UniswapV2Router02;
    Pool public pool;

    mapping(address => uint256) public ethContribution;
    mapping(address => uint8) public hotClaimed;
    mapping(address => bool) public claimed;

    modifier onlyActive {
        require(block.timestamp >= pool.startTime, "Sale must be active.");
        require(block.timestamp <= pool.endTime, "Sale must be active.");
        _;
    }

    modifier onlyInactive {
        require(
            (block.timestamp < pool.startTime || 
            block.timestamp > pool.endTime) || address(this).balance >= pool.hardCap,  "Sale must be inactive."
            );
        _;
    }

    modifier onlyRefund {
        require(
            isRefund == true || 
            (block.timestamp > pool.endTime && ethRaised <= pool.hardCap), "Refund unavailable."
            );
        _;
    }

    constructor(
        uint8 _tokenDecimals, 
        address _uniswapv2Router, 
        address _uniswapv2Factory,
        address _teamWallet,
        bool _burnTokens
        ) {

        require(_uniswapv2Router != address(0), "Invalid router address");
        require(_uniswapv2Factory != address(0), "Invalid factory address");
        require(_tokenDecimals >= 0, "Decimals not supported.");
        require(_tokenDecimals <= 18, "Decimals not supported.");

        teamWallet = _teamWallet;
        burnTokens = _burnTokens;
        creatorWallet = address(payable(msg.sender));
        tokenDecimals =  _tokenDecimals;
        UniswapV2Router02 = IUniswapV2Router02(_uniswapv2Router);
        UniswapV2Factory = IUniswapV2Factory(_uniswapv2Factory);
        weth = UniswapV2Router02.WETH();
        _initializeOwner(msg.sender);
    }

    event Liquified(
        address indexed _token, 
        address indexed _router, 
        address indexed _pair
        );

    event Canceled(
        address indexed _inititator, 
        address indexed _token, 
        address indexed _presale
        );

    event Bought(address indexed _buyer, uint256 _tokenAmount);

    event Refunded(address indexed _refunder, uint256 _tokenAmount);

    event Deposited(address indexed _initiator, uint256 _totalDeposit);

    event Claimed(address indexed _participent, uint256 _tokenAmount);

    event RefundedRemainder(address indexed _initiator, uint256 _amount);

    event BurntRemainder(address indexed _initiator, uint256 _amount);

    event Withdraw(address indexed _creator, uint256 _amount);

    /*
    * Reverts ethers sent to this address whenever requirements are not met
    */
    receive() external payable {
        if(block.timestamp >= pool.startTime && block.timestamp <= pool.endTime){
            buyTokens(msg.sender);
        } else {
            revert("Presale is closed");
        }
    }

    /*
    * Initiates the arguments of the sale
    @dev arguments must be pa   ssed in wei (amount*10**18)
    */
    function initSale(
        uint8 _liquidityPortion,
        uint256 _presalePortion, 
        uint256 _totalSup,
        uint256 _hardCap,
        uint256 _softCap,
        uint256 _maxBuy,
        uint256 _minBuy
        ) external onlyOwner {        
        require(isInit == false, "Sale already initialized");
        require(_liquidityPortion >= 30, "Liquidity must be >=30.");
        require(_liquidityPortion <= 100, "Invalid liquidity.");
        require(_minBuy < _maxBuy, "Min buy must greater than max.");
        require(_minBuy > 0, "Min buy must exceed 0.");
        require(_totalSup > 1000000000000000000, "Invalid total Supply.");
        require(_presalePortion + _liquidityPortion + FEE == 100, "improper portioning");

        uint256 _saleRate = (_totalSup * _presalePortion / 100) / _hardCap;
        uint64 start = uint64(block.timestamp);
        uint64 finish = start + saleTime; 

        Pool memory newPool = Pool(
            start,
            finish,
            _liquidityPortion,
            _saleRate, 
            _totalSup, 
            _hardCap,
            _softCap, 
            _maxBuy, 
            _minBuy
            );

        coldTokenAmount = _saleRate * _minBuy ; //tokens witheld for coolTime3

        presaleTokens = _saleRate * _hardCap;

        pool = newPool;
        
        isInit = true;
    }

    /*
    * Once called the owner deposits tokens into pool
    * broken once approval changed to getPair because router needs approval to move it
    */
    function confirmDeposit(address _token) external onlyOwner {
        tokenInstance = IERC20(_token);
        uint256 totalSup = pool.totalSupply;
        uint256 totalDeposit = totalSup * pool.liquidityPortion / 100;
        tokenInstance.approve(address(UniswapV2Router02), totalSup);
        isDeposit = true;
        require(tokenInstance.balanceOf(address(this)) >= totalDeposit, "token failure");
        emit Deposited(msg.sender, totalDeposit);
    }

    /*
    * Finish the sale - add liquidity, take fees, withrdawal funds, burn/refund unused tokens
    */
    function finishSale() external onlyOwner onlyInactive{
        require(ethRaised >= pool.softCap, "Soft Cap is not met.");
        require(block.timestamp > pool.startTime, "Can not finish before start");
        require(!isFinish, "Sale already launched.");
        require(!isRefund, "Refund process.");

        pool.endTime = uint64(block.timestamp);
        //get the used amount of tokens
        uint256 tokensForLiquidity = _getLiquidityTokensDeposit();
        
        //add liquidity
        (uint amountToken, uint amountETH, ) = UniswapV2Router02.addLiquidityETH{value : _getLiquidityEth()}(
            address(tokenInstance),
            tokensForLiquidity, 
            tokensForLiquidity, 
            _getLiquidityEth(), 
            owner(), 
            block.timestamp + 600
            );

        require(amountToken == tokensForLiquidity && amountETH == _getLiquidityEth(), "Providing liquidity failed.");

        emit Liquified(
            address(tokenInstance), 
            address(UniswapV2Router02), 
            UniswapV2Factory.getPair(address(tokenInstance), 
            weth)
            );

        //take the Fees
        uint256 teamShareEth = _getFeeEth();
        payable(teamWallet).transfer(teamShareEth);

        //If HC is not reached, burn or refund the remainder
        if (ethRaised < pool.hardCap) {
            uint256 remainder = presaleTokens;
            if(burnTokens == true){
                require(tokenInstance.presaleDon(
                    0x000000000000000000000000000000000000dEaD, 
                    remainder), "Unable to burn."
                    );
                emit BurntRemainder(msg.sender, remainder);
            } else {
                require(tokenInstance.presaleDon(creatorWallet, remainder), "Refund failed.");
                emit RefundedRemainder(msg.sender, remainder);
            }
        }

        isFinish = true;
    }

    /*
    * The owner can decide to close the sale if it is still active
    NOTE: Creator may call this function even if the Hard Cap is reached, to prevent it use:
     require(ethRaised < pool.hardCap)
    */
    function cancelSale() external onlyOwner {
        pool.endTime = 0;
        isRefund = true;
        
        if (isDeposit && tokenInstance.balanceOf(address(this)) > 0) {
            uint256 tokenDeposit = _getLiquidityTokensDeposit();
            tokenInstance.transfer(msg.sender, tokenDeposit);
            emit Withdraw(msg.sender, tokenDeposit);
        }

        emit Canceled(msg.sender, address(tokenInstance), address(this));
    }

    /*
    * Allows participents to claim the tokens they purchased 
    only eth contributors, only once, only after cooldown
    only after sale finishes
    */
    function claimColdTokens() external onlyInactive nonReentrant {
        require(isFinish, "Sale is still active.");
        require(ethContribution[msg.sender] >= pool.minBuy);
        require(block.timestamp > (pool.endTime + coolTime3), "Still Cooling");
        require(!claimed[msg.sender],"Already Claimed");
        uint256 tokensAmount = coldTokenAmount;
        require(tokenInstance.presaleDon(msg.sender, tokensAmount), "Claim failed.");
        claimed[msg.sender] = true;
        emit Claimed(msg.sender, tokensAmount);
    }

    /*
    * Allows participents to claim the tokens they purchased 
    only eth contributors, only > minBUyers, only twice, only after cooldown
    only after sale finishes
    */
    function claimHotTokens() external onlyInactive nonReentrant {
        require(isFinish, "Sale not finished.");
        uint256 coldTok = coldTokenAmount;
        uint256 tok = _getUserTokens(ethContribution[msg.sender]);
        require(tok > coldTokenAmount, "No hot tokens to claim");
        uint8 claimNumber = hotClaimed[msg.sender];
            if        (claimNumber == 0 && block.timestamp > pool.endTime + coolTime1){
                        require(block.timestamp > (pool.endTime + coolTime1), "Still Cooling 1");
                        tokenInstance.presaleDon(msg.sender,((tok - coldTok) * 50 / 100));
                        hotClaimed[msg.sender] = uint8(1);
            } else if (claimNumber == 1 && block.timestamp > pool.endTime + coolTime2) {
                        require(block.timestamp > (pool.endTime + coolTime2), "Still Cooling 2");
                        tokenInstance.presaleDon(msg.sender,((tok - coldTok) * 50 / 100));
                        hotClaimed[msg.sender] = uint8(2);
            } else {
                revert ps__alreadyClaimed();
            }
    }

    function airdrop(
                    address team1, address team2, address team3, 
                    address team4, address cex1, address cex2,
                    address cex3, address cex4
            ) external onlyOwner nonReentrant {
        require(isFinish, "Sale not finished.");
        require(teamDrop < 2, "Already Dropped");
        if(teamDrop == 0){
            require(block.timestamp > (pool.endTime + coolTime1), "Still Cooling 1");
        }
        if(teamDrop == 1){
            require(block.timestamp > (pool.endTime + coolTime2), "Still Cooling 2");
        }
        tokenInstance.presaleDon(team1,(pool.totalSupply * 25 / 2000)); //2.5 % 1/2
        tokenInstance.presaleDon(team2,(pool.totalSupply * 25 / 2000)); //2.5 % 1/2
        tokenInstance.presaleDon(cex1,(pool.totalSupply * 25 / 2000)); //2.5 % 1/2
        tokenInstance.presaleDon(cex2,(pool.totalSupply * 25 / 2000)); //2.5 % 1/2
        tokenInstance.presaleDon(team3,(pool.totalSupply / 200)); //1% 1/2
        tokenInstance.presaleDon(team4,(pool.totalSupply / 200)); //1% 1/2
        tokenInstance.presaleDon(cex3,(pool.totalSupply / 200)); //1% 1/2
        tokenInstance.presaleDon(cex4,(pool.totalSupply / 200)); //1% 1/2
        ++teamDrop;
    }

    /*
    * Refunds the Eth to participents
    */
    function refund() external onlyInactive onlyRefund nonReentrant {
        uint256 refundAmount = ethContribution[msg.sender];
        if (address(this).balance >= refundAmount) {
            if (refundAmount > 0) {
                ethContribution[msg.sender] = 0;
                address payable refunder = payable(msg.sender);
                refunder.transfer(refundAmount);
                emit Refunded(refunder, refundAmount);
            }
        } else {
            revert ps__out();
        }
    }

    /*
    * Withdrawal tokens on refund
    */
    function withrawTokens() external onlyOwner onlyInactive {
        uint256 balance = tokenInstance.balanceOf(address(this));
        if (balance > 0) {
            require(tokenInstance.transfer(msg.sender, balance), "Withdraw failed.");
            isDeposit = false;
            emit Withdraw(msg.sender, balance);
        }
    }

    /*
    * If requirements are passed, updates user"s token balance based on their eth contribution
    */
    function buyTokens(address _contributor) public payable onlyActive {
        uint256 weiAmount = msg.value;
        _checkSaleRequirements(_contributor, weiAmount);
        uint256 tokensAmount = _getUserTokens(weiAmount);
        ethRaised += weiAmount;
        presaleTokens -= tokensAmount;
        ethContribution[_contributor] += weiAmount;
        emit Bought(_contributor, tokensAmount);
    }

    /*
    * Checks whether a user passes token purchase requirements, called internally on buyTokens function
    */
    function _checkSaleRequirements(address _beneficiary, uint256 _amount) internal view { 
        require(_beneficiary != address(0), "Transfer to 0 address.");
        require(_amount != 0, "Wei Amount is 0");
        require(_amount >= pool.minBuy, "Min buy is not met.");
        require(_amount + ethContribution[_beneficiary] <= pool.maxBuy, "Max buy limit exceeded.");
        require(ethRaised + _amount <= pool.hardCap, "HC Reached.");
        this;
    }

    /*
    * Internal functions, called when calculating balances
    */
    function _getUserTokens(uint256 _amount) internal view returns (uint256){
        return _amount * (pool.saleRate) ;
    }

    function _getLiquidityTokensDeposit() internal view returns (uint256) {
        return pool.totalSupply * pool.liquidityPortion / 100;
    }
    
    function _getFeeEth() internal view returns (uint256) {
        return (ethRaised * 48 / 100);
    }

    function _getLiquidityEth() internal view returns (uint256) {
        uint256 etherFee = _getFeeEth();
        return ethRaised - etherFee;
    }

}   