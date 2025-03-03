// SPDX-License-Identifier: MIT

//@author 0xPhant0m based on Ohm Bond Depository and Bond Protocol

pragma solidity ^0.8.27;  

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract BondDepository is AccessControlEnumerable, ReentrancyGuard {
  using SafeERC20 for IERC20;

    bytes32 public constant AUCTIONEER_ROLE = keccak256("AUCTIONEER_ROLE");
    bytes32 public constant TOKEN_WHITELISTER_ROLE = keccak256("TOKEN_WHITELISTER_ROLE");
    bytes32 public constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN_ROLE");

    bool public paused;


    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event newBondCreated(uint256 indexed id, address indexed payoutToken, address indexed quoteToken, uint256 initialPrice );
    event BondEnded(uint256 indexed id);
    event addedAuctioneer(address _auctioneer, address payoutToken);
    event removeAuctioneer(address auctioneer);
    event MarketTransferred( uint256 marketId, address owner, address newAuctioneer);
    event BondDeposited( address indexed user,  uint256 indexed marketId,  uint256 depositAmount, uint256 totalOwed, uint256 bondPrice );
    event QuoteTokensWithdrawn( uint256 indexed marketId, address indexed auctioneer, uint256 amount, uint256 daoFee );
    event FeeUpdated (uint256 oldFee, uint256 basePoints);
    event TokenUnwhitelisted( address _token);
    event TokenWhitelisted( address _token);
 


    uint256 public marketCounter;
    address [] public _payoutTokens;
    Terms[] public terms;
    mapping(uint256 => Adjust) public adjustments;
    mapping (address => bool) _whitelistedAuctioneer;
    mapping (address => bool) _whitelistedToken;
    mapping(uint256 => address) public marketsToAuctioneers;
    mapping(address => uint256[]) public marketsForQuote;
    mapping(address => uint256[]) public marketsForPayout;
    mapping( address => Bond[]) public bondInfo; 
    address public immutable mSig;
    uint256 public feeToDao;
    uint256 public constant MAX_FEE = 1000; 


 // Info for creating new bonds
    struct Terms {
        address quoteToken; //token requested 
        address payoutToken; //token to be redeemed
        uint256 amountToBond; //Amount of payout Tokens dedicated to this request
        uint256 totalDebt;
        uint256 controlVariable; // scaling variable for price
        uint256 minimumPrice; // vs principle value add 3 decimals of precision
        uint256 maxDebt; // 9 decimal debt ratio, max % total supply created as debt
        uint256 quoteTokensRaised; 
        uint256 lastDecay; //block.timestamp of last decay (i.e last deposit)
        uint32 bondEnds; //Unix Timestamp of when the offer ends.
        uint32 vestingTerm; // How long each bond should vest for in seconds
    }

    struct Bond {
        address tokenBonded; //token to be distributed
        uint256 initialAmount; //Total initial amount of the bond
        uint256 amountOwed; //amount of tokens still owed to Bonder
        uint256 pricePaid; //price paid in PayoutToken
        uint256 marketId; //Which market does this belong
        uint32 startTime; // block timestamp
        uint32 endTime; //timestamp
    }

      struct Adjust {
        bool add; // addition or subtraction
        uint rate; // increment
        uint target; // BCV when adjustment finished
        uint buffer; // minimum length (in blocks) between adjustments
        uint lastBlock; // block when last adjustment made
      }

        //Strictly for front-end optimization
     struct BondMarketInfo {
        address quoteToken;
        address payoutToken;
        uint256 price;
        uint256 maxPayout;
        uint256 vestingTerm;
        uint256 amountToBond;
        address auctioneer;
        bool isLive;
        uint256 totalDebt;
        uint256 bondEnds;
}

    constructor(address _mSig){
      if (_mSig == address (0)) revert ("Invalid address");
        mSig = _mSig;
     _grantRole(DEFAULT_ADMIN_ROLE, mSig);
       _grantRole(EMERGENCY_ADMIN_ROLE, mSig);
        _grantRole(TOKEN_WHITELISTER_ROLE, mSig);

    }

                                         /*================================= Auctioneer FUNCTIONS =================================*/

    function newBond( 
    address payoutToken_, 
    IERC20 _quoteToken,
    uint256 [4] memory _terms,  // [amountToBond, controlVariable, minimumPrice, maxDebt]
    uint32 [2] memory _vestingTerms  // [bondEnds, vestingTerm]
) external onlyRole(AUCTIONEER_ROLE) whenNotPaused returns (uint256 marketID) {
    // Address validations
    require(payoutToken_ != address(0), "Invalid payout token");
    require(address(_quoteToken) != address(0), "Invalid quote token");
    require(address(_quoteToken) != payoutToken_, "Tokens must be different");
    require(_whitelistedToken[payoutToken_], "Token not whitelisted");
    require(!auctioneerHasMarketForQuote(msg.sender, address(_quoteToken)), "Already has market for quote token");
    
    // Time validations
    require(_vestingTerms[0] > block.timestamp, "Bond end too early"); 
    // Parameter validations
    require(_terms[0] > 0, "Amount must be > 0");
    require(_terms[1] > 0, "Control variable must be > 0");
    require(_terms[2] > 0, "Minimum price must be > 0");
    require(_terms[3] > 0, "Max debt must be > 0");
    
    uint256 secondsToConclusion = _vestingTerms[0] - block.timestamp;
    require(secondsToConclusion > 0, "Invalid vesting period");
    
    // Calculate max payout with better precision
   uint8 payoutDecimals = IERC20Metadata(payoutToken_).decimals();


    // Transfer payout tokens 

   IERC20(payoutToken_).safeTransferFrom(msg.sender, address(this), _terms[0] * 10**payoutDecimals); 
    
    // Create market
    terms.push(Terms({
       quoteToken: address(_quoteToken),
       payoutToken: payoutToken_,
       amountToBond: _terms[0] * 10**payoutDecimals,  
       controlVariable: _terms[1],
       minimumPrice: (_terms[2] * 10 ** 18) / 1000,
       maxDebt: _terms[3] * 10**payoutDecimals,  
       quoteTokensRaised: 0,
       lastDecay: block.timestamp,
       bondEnds: _vestingTerms[0],
       vestingTerm: _vestingTerms[1],
       totalDebt: 0
    }));
    
    // Market tracking
    uint256 marketId = marketCounter;
    marketsForPayout[payoutToken_].push(marketId);
    marketsForQuote[address(_quoteToken)].push(marketId);
    marketsToAuctioneers[marketId] = msg.sender;
    
    ++marketCounter;
    emit newBondCreated(marketId, payoutToken_, address(_quoteToken), _terms[1]);
    
    return marketId;
}
  
   function closeBond(uint256 _id) external onlyRole(AUCTIONEER_ROLE) whenNotPaused {
    if (marketsToAuctioneers[_id] != msg.sender) revert ("Not your Bond");
    terms[_id].bondEnds = uint32(block.timestamp);

    uint256 amountLeft = terms[_id].amountToBond - terms[_id].totalDebt;

    IERC20(terms[_id].payoutToken).safeTransfer(msg.sender, amountLeft);

    emit BondEnded(_id);
}

  function withdrawQuoteTokens(uint256 _id) external onlyRole(AUCTIONEER_ROLE) whenNotPaused {
    require(marketsToAuctioneers[_id] == msg.sender, "Not market's auctioneer");
    require(block.timestamp > terms[_id].bondEnds, "Bond not yet concluded");

    address quoteToken = terms[_id].quoteToken;
    uint256 balance = terms[_id].quoteTokensRaised;

    uint256 daoFee = 0;
    if (feeToDao > 0) {
        daoFee = (balance * feeToDao) / 10000;
        balance -= daoFee;
    }

    IERC20(quoteToken).safeTransfer(msg.sender, balance);
    if (daoFee > 0) {
        IERC20(quoteToken).safeTransfer(mSig, daoFee);
    }

    emit QuoteTokensWithdrawn(_id, msg.sender, balance, daoFee);
}
    
    function transferMarket(uint256 marketId, address newAuctioneer) external {
    require(marketsToAuctioneers[marketId] == msg.sender, "Not market owner");
    require(hasRole(AUCTIONEER_ROLE, newAuctioneer), "Not auctioneer");
    marketsToAuctioneers[marketId] = newAuctioneer;
    emit MarketTransferred(marketId, msg.sender, newAuctioneer);
}

                             /*================================= User FUNCTIONS =================================*/
 
   function deposit(uint256 _id, uint256 amount, address user) public nonReentrant {
    require(user != address(0), "Invalid user address");
    require(_id < terms.length, "Invalid market ID");
    Terms storage term = terms[_id];
    require(block.timestamp <= term.bondEnds, "Bond has ended");
    require(term.totalDebt < term.maxDebt, "Maximum bond capacity reached");

    uint8 quoteDecimals = IERC20Metadata(address(term.quoteToken)).decimals();
    uint256 minimumDeposit = calculateMinimumDeposit(quoteDecimals);
    require(amount >= minimumDeposit, "Deposit below minimum threshold");

    _tune(_id);
    _decayDebt(_id);

    uint256 price = _marketPrice(_id);
    uint256 payout = (amount * 1e18) / price;
    uint256 maxPayout = ((term.maxDebt - term.totalDebt) * 1800) / 10000;
    
    require(payout <= maxPayout, "Deposit exceeds maximum allowed");
    require(term.totalDebt + payout <= term.maxDebt, "Exceeds maximum bond debt");

    IERC20 quoteToken = IERC20(term.quoteToken);
    uint256 balanceBefore = quoteToken.balanceOf(address(this));
    quoteToken.safeTransferFrom(msg.sender, address(this), amount);
    uint256 balanceAfter = quoteToken.balanceOf(address(this));
    require(balanceAfter - balanceBefore == amount, "Incorrect transfer amount");
    
    terms[_id].quoteTokensRaised += amount;
    terms[_id].totalDebt += payout;

    bondInfo[user].push(Bond({
        tokenBonded: term.payoutToken,
        amountOwed: payout,
        pricePaid: price,
        marketId: _id,
        startTime: uint32(block.timestamp),
        endTime: uint32(term.vestingTerm + block.timestamp)
    }));
        emit BondDeposited(user, _id, amount, payout, price); 
   }


  function redeem(uint256 _id, address user) external nonReentrant returns (uint256 amountRedeemed) {
    uint256 length = bondInfo[user].length; 
    uint256 totalRedeemed = 0; 
    
    // First pass: calculate total amount to redeem
    for (uint256 i = 0; i < length; i++) {
        Bond memory currentBond = bondInfo[user][i];
        if (currentBond.marketId == _id) {
            uint256 amount = calculateLinearPayout(user, i);
            if (amount > 0) {
                totalRedeemed += amount;
            }
        }
    }
    
    if (totalRedeemed == 0) return 0;
    
    // Transfer total amount
    IERC20(terms[_id].payoutToken).safeTransfer(user, totalRedeemed);
    
    // Second pass: update bond records
    // We iterate backwards to safely remove items from array
    for (uint256 i = length; i > 0;) {
        i--;
        Bond storage currentBond = bondInfo[user][i];
        if (currentBond.marketId == _id) {
            uint256 amount = calculateLinearPayout(user, i);
            if (amount > 0) {
                currentBond.amountOwed -= amount;
                
                // If bond is fully redeemed, remove it
                if (currentBond.amountOwed == 0) {
                    // Move the last item to this position and remove the last item
                    if (i != bondInfo[user].length - 1) {
                        bondInfo[user][i] = bondInfo[user][bondInfo[user].length - 1];
                    }
                    bondInfo[user].pop();
                }
            }
        }
    }
    
    return totalRedeemed;
}



    
  
                           /*================================= ADMIN FUNCTIONS =================================*/

    function grantAuctioneerRole(address _auctioneer) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        // Additional validation
        require(_auctioneer != address(0), "Invalid auctioneer address");
        require(!hasRole(AUCTIONEER_ROLE, _auctioneer), "Already an auctioneer");

        _grantRole(AUCTIONEER_ROLE, _auctioneer);
        _whitelistedAuctioneer[_auctioneer] = true;
        emit RoleGranted(AUCTIONEER_ROLE, _auctioneer, msg.sender);
    }

    function revokeAuctioneerRole(address _auctioneer) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        _revokeRole(AUCTIONEER_ROLE, _auctioneer);
        _whitelistedAuctioneer[_auctioneer] = false;
        emit RoleRevoked(AUCTIONEER_ROLE, _auctioneer, msg.sender);
    }

     function whitelistToken(address _token) 
        external 
        onlyRole(TOKEN_WHITELISTER_ROLE) 
    {
        require(_token != address(0), "Invalid token address");
        require(!_whitelistedToken[_token], "Token already whitelisted");

        // Additional token validation
        try IERC20Metadata(_token).decimals() returns (uint8) {
            _whitelistedToken[_token] = true;
            _payoutTokens.push(_token);
        } catch {
            revert("Invalid ERC20 token");
        }
    }

    function unwhitelistToken(address _token) external onlyRole(TOKEN_WHITELISTER_ROLE) {
    require(_whitelistedToken[_token], "Token not whitelisted");
    _whitelistedToken[_token] = false;
    emit TokenUnwhitelisted(_token);
}
    

     function pauseContract() 
        external 
        onlyRole(EMERGENCY_ADMIN_ROLE) 
    {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    function unpauseContract() 
        external 
        onlyRole(EMERGENCY_ADMIN_ROLE) 
    {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

   function setFeetoDao(uint32 basePoints) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(basePoints <= MAX_FEE, "Fee too high");
    uint256 oldFee = feeToDao;
    feeToDao = basePoints;
    emit FeeUpdated(oldFee, basePoints);
}

                            /*================================= View Functions =================================*/

    function getMarketsForQuote(address quoteToken) external view returns(uint256[] memory) {
         return marketsForQuote[quoteToken];
    }

    function getMarketsForPayout(address payout) external view returns(uint256[] memory) {
           return marketsForPayout[payout];
    }

    function getMarketsForUser(address user) external view returns(uint256[] memory) {
            uint256[] memory userMarkets = new uint256[](bondInfo[user].length);
    for (uint256 i = 0; i < bondInfo[user].length; i++) {
        userMarkets[i] = bondInfo[user][i].marketId;
    }
    return userMarkets;
    }
    
     function isLive(uint256 id_) public view returns (bool) {
         return block.timestamp <= terms[id_].bondEnds && terms[id_].totalDebt < terms[id_].maxDebt;
}
     
     function currentMaxPayout(uint256 _id) public view returns (uint256) {
       Terms memory term = terms[_id];
       uint256 remainingDebt = term.maxDebt - term.totalDebt;
       return (remainingDebt * 1800) / 10000;  // 18% of remaining
}
    
    function bondPrice(uint256 id_) public view returns(uint256) {
         return _trueBondPrice(id_);

  }

  
    function isAuctioneer(address account) external view returns (bool) {
        return hasRole(AUCTIONEER_ROLE, account);
    }

    function calculateLinearPayout(address user, uint256 _bondId) public view returns (uint256) {
        Bond memory bond = bondInfo[user][_bondId];
        
        // No payout if bond doesn't exist or nothing is owed
        if (bond.amountOwed == 0) return 0;
        
        // If bond is fully matured, return all remaining owed amount
        if (block.timestamp >= bond.endTime) {
            return bond.amountOwed;
        }
        
        // For active bonds, calculate linear vesting
        // Calculate what percentage of time has elapsed (in 1e18 precision)
        uint256 totalVestingDuration = bond.endTime - bond.startTime;
        uint256 timeElapsed = block.timestamp - bond.startTime;
        
        // Calculate what percentage is vested so far (with 1e18 precision)
        uint256 percentVested = (timeElapsed * 1e18) / totalVestingDuration;
        
        // Calculate total amount that should be vested by now
        uint256 totalAmountEarned = (percentVested * (bond.initialAmount)) / 1e18;
        
        // Calculate amount already claimed
        uint256 alreadyClaimed = bond.initialAmount - bond.amountOwed;
        
        // Calculate what can be claimed now
        if (totalAmountEarned > alreadyClaimed) {
            return totalAmountEarned - alreadyClaimed;
        }
        
        return 0;
    }


    function getBondMarketInfo(uint256 marketId) public view returns (BondMarketInfo memory) {
        Terms storage term = terms[marketId];
        
        return BondMarketInfo({
            quoteToken: term.quoteToken,
            payoutToken: term.payoutToken,
            price: _trueBondPrice(marketId),
            maxPayout: currentMaxPayout(marketId),
            vestingTerm: term.vestingTerm, 
            amountToBond: term.amountToBond,
            auctioneer: marketsToAuctioneers[marketId],
            isLive: isLive(marketId),
            totalDebt: term.totalDebt,
            bondEnds: term.bondEnds
        });
    }

    function getBondMarketInfoBatch(uint256[] calldata marketIds) external view returns (BondMarketInfo[] memory) {
    BondMarketInfo[] memory markets = new BondMarketInfo[](marketIds.length);
    
    for (uint256 i = 0; i < marketIds.length; i++) {
        markets[i] = getBondMarketInfo(marketIds[i]);
    }
    
    return markets;
}

  function payoutFor(address user, uint256 _bondId) public view returns (uint256 amount) {
    return calculateLinearPayout(user, _bondId);
}

   function isMature(address user, uint256 _bondId) public view returns (bool) {
    Bond memory bond = bondInfo[user][_bondId];
    return block.timestamp >= bond.endTime;
}
                             /*================================= Internal Functions =================================*/


   function _decayDebt(uint256 _id) internal {
    Terms storage term = terms[_id];
    
    uint256 currentDebt = term.totalDebt;
    if (currentDebt == 0) return;

    uint256 timeSinceLastDecay = block.timestamp - term.lastDecay;
    if (timeSinceLastDecay == 0) return;

    // Calculate decay as a proportion of time elapsed relative to vesting term
    // Scale by 1% to ensure reasonable decay rate (100 = 1% constant)
    uint256 decayRate = 100; // 1% coefficient for controlled decay
    uint256 decay = (currentDebt * timeSinceLastDecay) / (term.vestingTerm * decayRate); 
    
    // Ensure we don't decay more than current debt
    term.totalDebt = decay > currentDebt ? 0 : currentDebt - decay;
    term.lastDecay = uint32(block.timestamp);
}


        function _tune(uint256 _id) internal{
            if (block.timestamp > adjustments[_id].lastBlock + adjustments[_id].buffer) {
        Terms storage term = terms[_id];
        
        if (adjustments[_id].add) {
            term.controlVariable += adjustments[_id].rate;
            
            if (term.controlVariable >= adjustments[_id].target) {
                term.controlVariable = adjustments[_id].target;
            }
        } else {
            term.controlVariable -= adjustments[_id].rate;
            
            if (term.controlVariable <= adjustments[_id].target) {
                term.controlVariable = adjustments[_id].target;
            }
        }
        
        adjustments[_id].lastBlock = uint32(block.timestamp);
    }

        }

    function _marketPrice(uint256 _id) internal view returns (uint256 price) {
    Terms memory term = terms[_id];
    
    // Get decimals for both tokens for precise calculations
    uint8 payoutDecimals = IERC20Metadata(address(term.payoutToken)).decimals();
    uint8 quoteDecimals = IERC20Metadata(address(term.quoteToken)).decimals();
    
    // Get current control variable and debt ratio
    uint256 currentCV = _currentControlVariable(_id);
    uint256 debtRatio = _debtRatio(_id);
    
    // Early check for potential overflow
    if (currentCV > type(uint256).max / debtRatio) {
        return term.minimumPrice;
    }
    
    // Calculate base price with proper scaling
    uint256 rawPrice = currentCV * debtRatio;
    
    // Apply decimal adjustments
    int8 decimalAdjustment = int8(36) - int8(payoutDecimals) - int8(quoteDecimals);
    
    if (decimalAdjustment > 0) {
        // Scale up if needed
        rawPrice = rawPrice * (10 ** uint8(decimalAdjustment));
    }
    
    // Divide by 1e18 twice due to debtRatio scaling
    price = rawPrice / 1e18 / 1e18;
    
    // Apply minimum price floor
    if (price < term.minimumPrice) {
        price = term.minimumPrice;
    }
    
    // Final overflow guard
    if (price > type(uint256).max / 1e18) {
        price = type(uint256).max / 1e18;
    }
    
    return price;
}

        
        function _trueBondPrice(uint256 _id) internal view returns(uint256 price){
            
            price = _marketPrice(_id);
        }

     function _debtRatio(uint256 _id) internal view returns (uint256) {
  
    Terms memory term = terms[_id];
    
    // Get decimals for precise calculation
    uint8 quoteDecimals = uint8(IERC20Metadata(address(term.quoteToken)).decimals());
    uint8 payoutDecimals = uint8(IERC20Metadata(address(term.payoutToken)).decimals());

    // Normalize totalDebt to 18 decimals (totalDebt is in payoutToken)
    uint256 totalDebt = term.totalDebt * (10**(18 - payoutDecimals));
    
    // Normalize quote tokens raised to 18 decimals
    uint256 quoteBalance = term.quoteTokensRaised * (10 ** (18 - quoteDecimals));
    
    // Prevent division by zero
    if (quoteBalance == 0) { 
        return 1e18; 
    }

    // Calculate debt ratio with high precision
    // Result is scaled to 1e18
    uint256 debtRatio = (totalDebt * 1e18) / quoteBalance;
    
    return debtRatio;
}

         function _currentControlVariable(uint256 _id) internal view returns (uint256) {
    Terms memory term = terms[_id];
    Adjust memory adjustment = adjustments[_id];

    // Base control variable
    uint256 baseCV = term.controlVariable;

    // Market-adaptive decay calculation
    uint256 currentDebtRatio = _debtRatio(_id);
    uint256 timeSinceBondStart = block.timestamp > term.bondEnds 
        ? block.timestamp - term.bondEnds 
        : 0;
    
    // Adaptive decay rate based on debt ratio
    // Higher debt ratio accelerates decay
    uint256 adaptiveDecayRate = (currentDebtRatio * 1e18) / term.maxDebt;
    
    // Calculate decay amount
    uint256 decayAmount = (baseCV * adaptiveDecayRate) / (timeSinceBondStart + 1);

    // Apply ongoing adjustment if within adjustment window
    if (block.timestamp <= adjustment.lastBlock + adjustment.buffer) {
        if (adjustment.add) {
            // Increasing control variable
            baseCV += adjustment.rate;
            
            // Cap at target if exceeded
            if (baseCV > adjustment.target) {
                baseCV = adjustment.target;
            }
        } else {
            // Decreasing control variable
            baseCV -= adjustment.rate;
            
            // Floor at target if fallen below
            if (baseCV < adjustment.target) {
                baseCV = adjustment.target;
            }
        }
    }

    // Apply decay
    if (baseCV > decayAmount) {
        return baseCV - decayAmount;
    }
    
    return 0;
}

    // Helper function for minimum deposit calculation
        function calculateMinimumDeposit(uint8 decimals) internal pure returns (uint256) {
    // Ensures meaningful deposit across different token decimal configurations
          if (decimals > 2) {
          return 10 ** (decimals - 2);  // 1% of smallest token unit
    }
        return 1;  // Fallback for tokens with very few decimals
}

        // Helper function for precise owed calculation
        function calculateTotalOwed(uint256 amount, uint256 price) internal pure returns (uint256) {

         return amount * price; 
}

    function auctioneerHasMarketForQuote(address auctioneer, address quoteToken) public view returns (bool) {
    uint256[] memory markets = marketsForQuote[quoteToken];
    for(uint256 i = 0; i < markets.length; i++) {
       if(marketsToAuctioneers[markets[i]] == auctioneer && isLive(markets[i])) {         
            return true;
        }
    }
    return false;
}

          modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }
 
}
