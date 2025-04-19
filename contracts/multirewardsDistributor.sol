// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IVeSix.sol";

/**
* @title VeSixRewardDistributor
* @notice Distributes rewards to veNFT holders based on their farming power
* @dev Based on Synthetix's StakingRewards contract, adapted for veToken mechanics
*/
contract VeSixRewardDistributor is Initializable, ReentrancyGuardUpgradeable {
   using SafeERC20Upgradeable for IERC20Upgradeable;

   struct Reward {
       uint256 periodFinish;
       uint256 rewardRate;
       uint256 lastUpdateTime;
       uint256 rewardPerVeTokenStored;
       uint256 queuedRewards;
       uint256 lastTotalSupply;
       uint256 periodId;
   }

   struct HistoricalReward {
       uint256 amount;
       uint256 periodId;
   }

   /* ========== STATE VARIABLES ========== */

   IVeSix public veSix;
   address public distributor;
   
   mapping(address => Reward) public rewardData;
   mapping(address => bool) public isRewardToken;
   mapping(address => uint256) public currentPeriod;
   address[] public rewardTokens;
   
   mapping(address => mapping(uint256 => uint256)) public userRewardPerTokenPaid;
   mapping(address => mapping(uint256 => uint256)) public rewards;
   mapping(address => mapping(uint256 => HistoricalReward)) public historicalRewards;
   
   /* ========== CONSTANTS ========== */
   
   uint256 public constant DURATION = 7 days;
   uint256 public constant MINIMUM_RATE = 1e6;
   uint256 public constant MAXIMUM_RATE = 1e24;
   uint256 public constant PRECISION = 1e18;
   uint256 public constant MAX_REWARD_TOKENS = 50;
   
   uint256[49] private __gap;

   /* ========== EVENTS ========== */

   event RewardAdded(address token, uint256 reward, uint256 rewardRate, uint256 periodId);
   event RewardPaid(uint256 indexed tokenId, address indexed rewardsToken, uint256 reward, uint256 periodId);
   event RewardQueued(address token, uint256 amount, uint256 periodId);
   event RewardTokenAdded(address token, uint256 periodId);
   event RewardTokenRemoved(address token, uint256 periodId); 
   event DistributorUpdated(address newDistributor);
   event RewardsUpdated(uint256 indexed tokenId);

   /* ========== ERRORS ========== */

   error InvalidRewardToken();
   error InsufficientBalance();
   error RateTooLow();
   error RateTooHigh();
   error Unauthorized();
   error ZeroAddress();
   error TokenAlreadyAdded();
   error NoRewards();
   error TooManyRewardTokens();
   error InvalidVeSupply();
   error ArithmeticError();
   error TransferFailed();
   error InvalidState();

   /* ========== MODIFIERS ========== */

   modifier onlyDistributor() {
       if (msg.sender != distributor) revert Unauthorized();
       _;
   }

   modifier updateReward(uint256 tokenId) {
       uint256 veSupply = getTotalSupply();
       if (veSupply == 0 && veSix.epoch() > 0) revert InvalidVeSupply();
       
       for(uint i = 0; i < rewardTokens.length; i++) {
           address token = rewardTokens[i];
           Reward storage reward = rewardData[token];
           
           uint256 oldRewardPerToken = _calculateRewardPerToken(token, reward.lastTotalSupply);
           reward.rewardPerVeTokenStored = oldRewardPerToken;
           reward.lastUpdateTime = lastTimeRewardApplicable(token);
           reward.lastTotalSupply = veSupply;
           
           if (tokenId != 0) {
               // Ensure userRewardPerTokenPaid never exceeds rewardPerVeTokenStored
               if (userRewardPerTokenPaid[token][tokenId] > reward.rewardPerVeTokenStored) {
                   userRewardPerTokenPaid[token][tokenId] = reward.rewardPerVeTokenStored;
               }
               
               rewards[token][tokenId] = earned(token, tokenId);
               userRewardPerTokenPaid[token][tokenId] = reward.rewardPerVeTokenStored;
           }
       }
       _;
   }
   
   /* ========== CONSTRUCTOR & INITIALIZER ========== */

   constructor() {
       _disableInitializers();
   }

   function initialize(
       address _veSix,
       address _distributor
   ) external initializer {
       if (_veSix == address(0) || _distributor == address(0)) revert ZeroAddress();
       
       __ReentrancyGuard_init();
       
       veSix = IVeSix(_veSix);
       distributor = _distributor;
   }

   /* ========== ADMIN FUNCTIONS ========== */

   function addInitialRewardTokens(address[] memory _rewardTokens) external onlyDistributor {
       if (_rewardTokens.length > MAX_REWARD_TOKENS) revert TooManyRewardTokens();
       if (rewardTokens.length > 0) revert("Tokens already initialized");
       
       for(uint i = 0; i < _rewardTokens.length; i++) {
           for(uint j = i + 1; j < _rewardTokens.length; j++) {
               if (_rewardTokens[i] == _rewardTokens[j]) revert("Duplicate token");
           }
       }
       
       for(uint i = 0; i < _rewardTokens.length; i++) {
           _addRewardToken(_rewardTokens[i]);
       }
   }

   function updateDistributor(address _newDistributor) external onlyDistributor {
       if (_newDistributor == address(0)) revert ZeroAddress();
       distributor = _newDistributor;
       emit DistributorUpdated(_newDistributor);
   }

   function addRewardToken(address token) external onlyDistributor {
       _addRewardToken(token);
   }

   function _addRewardToken(address token) internal {
       if (token == address(0)) revert ZeroAddress();
       if (isRewardToken[token]) revert TokenAlreadyAdded();
       
       rewardTokens.push(token);
       isRewardToken[token] = true;
       currentPeriod[token] = 1;
       
       Reward storage reward = rewardData[token];
       reward.lastTotalSupply = 0;
       reward.periodId = currentPeriod[token];
       
       emit RewardTokenAdded(token, currentPeriod[token]);
   }

   function removeRewardToken(address _rewardsToken) external onlyDistributor {
       if (!isRewardToken[_rewardsToken]) revert InvalidRewardToken();
       
       Reward storage rewardInfo = rewardData[_rewardsToken];
       if (block.timestamp < rewardInfo.periodFinish) revert("Active rewards period");
       if (rewardInfo.queuedRewards > 0) revert("Pending rewards");
       
       uint256 currentTokenPeriod = currentPeriod[_rewardsToken];
       
       uint256 epoch = veSix.epoch();
       for (uint256 i = 1; i <= epoch; i++) {
           try veSix.ownerOf(i) returns (address) {  // Check if token exists
               uint256 currentReward = earned(_rewardsToken, i);
               if (currentReward > 0) {
                   historicalRewards[_rewardsToken][i] = HistoricalReward({
                       amount: currentReward,
                       periodId: currentTokenPeriod
                   });
               }
           } catch {}
       }
       
       isRewardToken[_rewardsToken] = false;
       currentPeriod[_rewardsToken] = currentTokenPeriod + 1;
       
       for (uint i = 0; i < rewardTokens.length; i++) {
           if (rewardTokens[i] == _rewardsToken) {
               rewardTokens[i] = rewardTokens[rewardTokens.length - 1];
               rewardTokens.pop();
               break;
           }
       }
       
       emit RewardTokenRemoved(_rewardsToken, currentTokenPeriod);
   }

   /* ========== REWARD FUNCTIONS ========== */

   function queueNewRewards(address _rewardsToken, uint256 amount) external onlyDistributor {
       if (!isRewardToken[_rewardsToken]) revert InvalidRewardToken();
       if (amount == 0) revert InvalidState();
       
       uint256 oldBalance = IERC20Upgradeable(_rewardsToken).balanceOf(address(this));
       IERC20Upgradeable(_rewardsToken).safeTransferFrom(msg.sender, address(this), amount);
       uint256 received = IERC20Upgradeable(_rewardsToken).balanceOf(address(this)) - oldBalance;
       
       rewardData[_rewardsToken].queuedRewards += received;
       
       emit RewardQueued(_rewardsToken, received, rewardData[_rewardsToken].periodId);
   }

   /**
    * @notice Notify the contract about new rewards to be distributed
    * @dev Following Synthetix's approach for calculating reward rates
    * @param _rewardsToken The token address for which rewards are being added
    * @param reward The amount of reward tokens to be distributed
    */
   function notifyRewardAmount(address _rewardsToken, uint256 reward) external onlyDistributor {
       if (!isRewardToken[_rewardsToken]) revert InvalidRewardToken();
       if (reward == 0) revert InvalidState();
       
       // Check actual token balance
       uint256 balance = IERC20Upgradeable(_rewardsToken).balanceOf(address(this));
       if (balance < reward) revert InsufficientBalance();
       
       Reward storage rewardInfo = rewardData[_rewardsToken];
       
       // If previous period has ended, increment period
       if (block.timestamp >= rewardInfo.periodFinish) {
           currentPeriod[_rewardsToken]++;
           rewardInfo.periodId = currentPeriod[_rewardsToken];
       }
       
       // Calculate reward rate following Synthetix's approach
       uint256 newRate;
       if (block.timestamp >= rewardInfo.periodFinish) {
           // If period has ended, simply set new rate
           newRate = reward / DURATION;
       } else {
           // If period is still active, include remaining rewards
           uint256 remaining = rewardInfo.periodFinish - block.timestamp;
           uint256 leftover = remaining * rewardInfo.rewardRate / PRECISION;
           newRate = (reward + leftover) / DURATION;
       }
       
       // Scale rate by PRECISION for consistency with calculation
       newRate = newRate * PRECISION;
       
       // Apply bounds checking
       if (newRate > MAXIMUM_RATE) {
           newRate = MAXIMUM_RATE;
       }
       if (newRate < MINIMUM_RATE) {
           revert RateTooLow();
       }
       
       // Update reward data
       rewardInfo.rewardRate = newRate;
       rewardInfo.lastUpdateTime = block.timestamp;
       rewardInfo.periodFinish = block.timestamp + DURATION;
       
       // Ensure lastTotalSupply is at least PRECISION
       uint256 currentSupply = getTotalSupply();
       rewardInfo.lastTotalSupply = currentSupply < PRECISION ? PRECISION : currentSupply;
       
       // Update reward per token stored
       rewardInfo.rewardPerVeTokenStored = _calculateRewardPerToken(_rewardsToken, rewardInfo.lastTotalSupply);
       
       emit RewardAdded(_rewardsToken, reward, newRate, rewardInfo.periodId);
   }

   /* ========== USER FUNCTIONS ========== */

   function claim(uint256 tokenId) public nonReentrant updateReward(tokenId) {
       if (veSix.ownerOf(tokenId) != msg.sender) revert Unauthorized();
       
       (address[] memory tokens, uint256[] memory amounts, uint256[] memory periods) = getClaimableRewards(tokenId);
       
       // Only process if there are rewards to claim
       if (tokens.length > 0) {
           for(uint i = 0; i < tokens.length; i++) {
               address token = tokens[i];
               uint256 amount = amounts[i];
               
               if (amount > 0) {
                   if (!isRewardToken[token]) revert InvalidRewardToken();
                   
                   Reward storage reward = rewardData[token];
                   
                   rewards[token][tokenId] = 0;
                   userRewardPerTokenPaid[token][tokenId] = reward.rewardPerVeTokenStored;
                   
                   historicalRewards[token][tokenId].amount = 0;
                   
                   _safeTransferReward(token, msg.sender, amount, tokenId, periods[i]);
               }
           }
       }
       
       emit RewardsUpdated(tokenId);
   }

   /**
    * @notice Allows updating rewards for a token without claiming
    * @param tokenId The token ID to update rewards for
    */
   function updateRewards(uint256 tokenId) external updateReward(tokenId) {
       emit RewardsUpdated(tokenId);
   }

   /* ========== INTERNAL FUNCTIONS ========== */

   function _safeTransferReward(
       address token, 
       address to, 
       uint256 amount, 
       uint256 tokenId,
       uint256 periodId
   ) internal {
       if (amount == 0) return;
       
       // If token is locked token, it is auto-compounded
       if (token == veSix.lockedToken()) {
           if (amount > type(uint128).max) revert("Amount too large");
           uint128 currentMultiplier = veSix.getCurrentMultiplier(tokenId);
           if (currentMultiplier == 0) revert("Invalid multiplier");
           
           uint128 minMultiplier = currentMultiplier * 95 / 100;  // 5% slippage allowance
           
           IERC20Upgradeable(token).approve(address(veSix), amount);
           try veSix.increaseLockAmount(
               tokenId, 
               uint128(amount), 
               block.timestamp,
               minMultiplier
           ) {
               emit RewardPaid(tokenId, token, amount, periodId);
               return;
           } catch {
               // Clear approval if increase fails
               IERC20Upgradeable(token).approve(address(veSix), 0);
               revert("Auto-compound failed");
           }
       }
       
       // For non-locked tokens, do regular transfer
       uint256 preBalance = IERC20Upgradeable(token).balanceOf(address(this));
       if (preBalance < amount) revert InsufficientBalance();
       
       uint256 recipientPreBalance = IERC20Upgradeable(token).balanceOf(to);
       
       IERC20Upgradeable(token).safeTransfer(to, amount);
       
       uint256 recipientPostBalance = IERC20Upgradeable(token).balanceOf(to);
       if (recipientPostBalance <= recipientPreBalance) revert TransferFailed();
       
       uint256 received = recipientPostBalance - recipientPreBalance;
       emit RewardPaid(tokenId, token, received, periodId);
   }

   /* ========== CALCULATION FUNCTIONS ========== */

   function getTotalSupply() public view returns (uint256) {
       return veSix.totalWeightedSupply();
   }

   function lastTimeRewardApplicable(address _rewardsToken) public view returns (uint256) {
       return block.timestamp < rewardData[_rewardsToken].periodFinish ? 
              block.timestamp : rewardData[_rewardsToken].periodFinish;
   }

   function _calculateRewardPerToken(address _rewardsToken, uint256 _supply) internal view returns (uint256) {
       if (_supply == 0) {
           return rewardData[_rewardsToken].rewardPerVeTokenStored;
       }
       
       uint256 timeDelta = lastTimeRewardApplicable(_rewardsToken) - rewardData[_rewardsToken].lastUpdateTime;
       if (timeDelta == 0) {
           return rewardData[_rewardsToken].rewardPerVeTokenStored;
       }
       
       // Calculate reward amount and additional reward per token
       uint256 rewardAmount = rewardData[_rewardsToken].rewardRate * timeDelta;
       uint256 additionalRewardPerToken = (rewardAmount * 1e18) / _supply;
       
       return rewardData[_rewardsToken].rewardPerVeTokenStored + additionalRewardPerToken;
   }

   function earned(address _rewardsToken, uint256 tokenId) public view returns (uint256) {
       Reward storage reward = rewardData[_rewardsToken];
       
       // Get current reward per token based on the last total supply
       uint256 currentRewardPerToken = _calculateRewardPerToken(
           _rewardsToken, 
           reward.lastTotalSupply
       );
       
       // Get user's last reward per token
       uint256 userPaid = userRewardPerTokenPaid[_rewardsToken][tokenId];
       
       // Safety check to prevent underflow
       if (userPaid > currentRewardPerToken) {
           return rewards[_rewardsToken][tokenId];
       }
       
       // Calculate epoch timestamp for farming power - this is the start of the reward period
       uint32 epochTimestamp = uint32((reward.periodFinish - DURATION) / 3600) * 3600;
       
       // Get farming power using historical data for consistency
       uint256 tokenWeight = veSix.getHistoricalFarmingPower(tokenId, epochTimestamp);
       
       if (tokenWeight == 0) {
           return rewards[_rewardsToken][tokenId];
       }
       
       // Calculate reward delta
       uint256 rewardDelta = currentRewardPerToken - userPaid;
       
       // Calculate pending reward with proper precision
       uint256 pendingReward = (tokenWeight * rewardDelta) / 1e18;
       
       // Add any stored rewards
       return pendingReward + rewards[_rewardsToken][tokenId];
   }

   /* ========== VIEW FUNCTIONS ========== */

   function getClaimableRewards(uint256 tokenId) public view returns (
       address[] memory tokens,
       uint256[] memory amounts,
       uint256[] memory periods
   ) {
       // Check if token exists and has a valid owner
       address owner = veSix.ownerOf(tokenId);
       if (owner == address(0)) revert InvalidState();
       
       address[] memory allTokens = getRewardTokens();
       tokens = new address[](allTokens.length * 2); // *2 for active and historical
       amounts = new uint256[](allTokens.length * 2);
       periods = new uint256[](allTokens.length * 2);
       
       uint256 count;
       for(uint i = 0; i < allTokens.length; i++) {
           address token = allTokens[i];
           
           // Active rewards
           uint256 activeReward = earned(token, tokenId);
           if (activeReward > 0) {
               tokens[count] = token;
               amounts[count] = activeReward;
               periods[count] = rewardData[token].periodId;
               count++;
           }
           
           // Historical rewards
           HistoricalReward memory historicalReward = historicalRewards[token][tokenId];
           if (historicalReward.amount > 0 && historicalReward.periodId < currentPeriod[token]) {
               tokens[count] = token;
               amounts[count] = historicalReward.amount;
               periods[count] = historicalReward.periodId;
               count++;
           }
       }
       
       // Resize arrays to match actual count
       assembly {
           mstore(tokens, count)
           mstore(amounts, count)
           mstore(periods, count)
       }
   }

   function getRewardTokens() public view returns (address[] memory) {
       return rewardTokens;
   }

   function getRewardTokenLength() external view returns (uint256) {
       return rewardTokens.length;
   }

   /**
    * @notice Calculates total pending rewards across all tokens and reward tokens
    * @return totalRewards The total amount of pending rewards
    */
   function getTotalPendingRewards() external view returns (uint256 totalRewards) {
       address[] memory allTokens = getRewardTokens();
       
       // Iterate through all reward tokens
       for(uint i = 0; i < allTokens.length; i++) {
           address token = allTokens[i];
           
           // Get current epoch
           uint256 epoch = veSix.epoch();
           
           // Iterate through all tokens up to current epoch
           for (uint256 j = 1; j <= epoch; j++) {
               try veSix.ownerOf(j) returns (address) {
                   // Add active rewards
                   uint256 activeReward = earned(token, j);
                   if (activeReward > 0) {
                       totalRewards += activeReward;
                   }
                   
                   // Add historical rewards
                   HistoricalReward memory historicalReward = historicalRewards[token][j];
                   if (historicalReward.amount > 0 && historicalReward.periodId < currentPeriod[token]) {
                       totalRewards += historicalReward.amount;
                   }
               } catch {
                   continue;
               }
           }
       }
       
       return totalRewards;
   }
}
