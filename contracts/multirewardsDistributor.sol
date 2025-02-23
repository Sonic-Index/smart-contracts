// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IVeSix.sol";

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

    // Storage variables v1
    IVeSix public veSix;
    address public distributor;

    
    mapping(address => Reward) public rewardData;
    mapping(address => bool) public isRewardToken;
    mapping(address => uint256) public currentPeriod;
    address[] public rewardTokens;
    
    mapping(address => mapping(uint256 => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(uint256 => uint256)) public rewards;
    mapping(address => mapping(uint256 => HistoricalReward)) public historicalRewards;
    
    uint256 public constant DURATION = 7 days;
    uint256 public constant MINIMUM_RATE = 1e6;
    uint256 public constant MAXIMUM_RATE = 1e24;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_REWARD_TOKENS = 50;
    
    // Storage gap for future upgrades
    uint256[50] private __gap;

    event RewardAdded(address token, uint256 reward, uint256 rewardRate, uint256 periodId);
    event RewardPaid(uint256 indexed tokenId, address indexed rewardsToken, uint256 reward, uint256 periodId);
    event RewardQueued(address token, uint256 amount, uint256 periodId);
    event RewardTokenAdded(address token, uint256 periodId);
    event RewardTokenRemoved(address token, uint256 periodId);
    event DistributorUpdated(address newDistributor);

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
    

    modifier onlyDistributor() {
        if (msg.sender != distributor) revert Unauthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
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

    function addInitialRewardTokens(address[] memory _rewardTokens) external onlyDistributor {
        if (_rewardTokens.length > MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        if (rewardTokens.length > 0) revert("Tokens already initialized");
        
        // Check for duplicates
        for(uint i = 0; i < _rewardTokens.length; i++) {
            for(uint j = i + 1; j < _rewardTokens.length; j++) {
                if (_rewardTokens[i] == _rewardTokens[j]) revert("Duplicate token");
            }
        }
        
        for(uint i = 0; i < _rewardTokens.length; i++) {
            _addRewardToken(_rewardTokens[i]);
        }
    }

    function updateDistributor(address _newDistributor) external  onlyDistributor{
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
        reward.lastTotalSupply = 0;  // Start at 0, will be updated on first reward
        reward.periodId = currentPeriod[token];
        
        emit RewardTokenAdded(token, currentPeriod[token]);
    }


    function getTotalSupply() public view returns (uint256) {
        return veSix.totalWeightedSupply();
    }


    modifier updateReward(uint256 tokenId) {
        uint256 veSupply = getTotalSupply();
        if (veSupply == 0 && veSix.epoch() > 0) revert InvalidVeSupply();
        
        for(uint i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            Reward storage reward = rewardData[token];
            
            reward.rewardPerVeTokenStored = _calculateRewardPerToken(token, veSupply);
            reward.lastUpdateTime = lastTimeRewardApplicable(token);
            reward.lastTotalSupply = veSupply;
            
            if (tokenId != 0) {
                rewards[token][tokenId] = earned(tokenId, token);
                userRewardPerTokenPaid[token][tokenId] = reward.rewardPerVeTokenStored;
            }
        }
        _;
    }

    function lastTimeRewardApplicable(address _rewardsToken) public view returns (uint256) {
        return block.timestamp < rewardData[_rewardsToken].periodFinish ? 
               block.timestamp : rewardData[_rewardsToken].periodFinish;
    }

      function _calculateRewardPerToken(address _rewardsToken, uint256 _supply) internal view returns (uint256) {
        Reward storage reward = rewardData[_rewardsToken];
        
        if (_supply == 0 || !isRewardToken[_rewardsToken]) {
            return reward.rewardPerVeTokenStored;
        }
        
        // Calculate new rewards since last update
        uint256 timeDelta = lastTimeRewardApplicable(_rewardsToken) - reward.lastUpdateTime;
        if (timeDelta == 0) return reward.rewardPerVeTokenStored;
        
        // Calculate additional rewardPerToken
        uint256 rewardAmount = timeDelta * reward.rewardRate;
        uint256 additionalRewardPerToken = (rewardAmount * PRECISION) / _supply;
        
        // Add to existing cumulative rewardPerToken
        return reward.rewardPerVeTokenStored + additionalRewardPerToken;
    }
    function earned(uint256 tokenId, address _rewardsToken) public view returns (uint256) {
        if (!isRewardToken[_rewardsToken]) return 0;
        
        Reward memory reward = rewardData[_rewardsToken];
        if (reward.lastUpdateTime == 0) return 0;
        
        // Convert to uint32 for VeSix
        uint32 epochTimestamp = uint32((reward.lastUpdateTime / 3600) * 3600);
        uint256 balance = veSix.getFarmingPower(tokenId, epochTimestamp);
        if (balance == 0) return rewards[_rewardsToken][tokenId];
        
        // Rest of function remains the same
        uint256 currentRewardPerToken = reward.rewardPerVeTokenStored;
        uint256 userPaid = userRewardPerTokenPaid[_rewardsToken][tokenId];
        uint256 rewardDelta = currentRewardPerToken >= userPaid ? 
            currentRewardPerToken - userPaid : 0;
        
        uint256 pendingReward = (balance * rewardDelta) / PRECISION;
        return rewards[_rewardsToken][tokenId] + pendingReward;
    }

    function queueNewRewards(address _rewardsToken, uint256 amount) external onlyDistributor {
        if (!isRewardToken[_rewardsToken]) revert InvalidRewardToken();
        if (amount == 0) revert InvalidState();
        
        uint256 oldBalance = IERC20Upgradeable(_rewardsToken).balanceOf(address(this));
        IERC20Upgradeable(_rewardsToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20Upgradeable(_rewardsToken).balanceOf(address(this)) - oldBalance;
        
        rewardData[_rewardsToken].queuedRewards += received;
        
        emit RewardQueued(_rewardsToken, received, rewardData[_rewardsToken].periodId);
    }

     function notifyRewardAmount(address _rewardsToken, uint256 reward) external onlyDistributor {
        if (!isRewardToken[_rewardsToken]) revert InvalidRewardToken();
        if (reward == 0) revert InvalidState();
        
        // Force update rewardPerVeTokenStored with old rate before changing rate
        uint256 veSupply = getTotalSupply();
        rewardData[_rewardsToken].rewardPerVeTokenStored = _calculateRewardPerToken(_rewardsToken, veSupply);
        
        // Set new rate
        uint256 newRate = reward / DURATION;
        rewardData[_rewardsToken].rewardRate = newRate;
        rewardData[_rewardsToken].lastUpdateTime = block.timestamp;
        rewardData[_rewardsToken].periodFinish = block.timestamp + DURATION;
        rewardData[_rewardsToken].lastTotalSupply = veSupply;
        
        emit RewardAdded(_rewardsToken, reward, newRate, rewardData[_rewardsToken].periodId);
    }

    function getRewardForTokens(uint256[] calldata tokenIds) external {
        if (tokenIds.length > 100) revert InvalidState();
        
        for(uint i = 0; i < tokenIds.length; i++) {
            if (veSix.isApprovedOrOwner(msg.sender, tokenIds[i])) {
                claim(tokenIds[i]) ;
            }
        }
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
                uint256 currentReward = earned(i, _rewardsToken);
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

    function claim(uint256 tokenId) public nonReentrant updateReward(tokenId) {
        if (msg.sender != veSix.ownerOf(tokenId)) revert Unauthorized();
        
        bool hasReward;
        address[] memory allTokens = getRewardTokens();
        
        for(uint i = 0; i < allTokens.length; i++) {
            address token = allTokens[i];
            
            // Active rewards
            uint256 activeReward = earned(tokenId, token);
            if (activeReward > 0) {
                hasReward = true;
                rewards[token][tokenId] = 0;
                _safeTransferReward(token, msg.sender, activeReward, tokenId, rewardData[token].periodId);
            }
            
            // Historical rewards - only if from previous period
            HistoricalReward memory historicalReward = historicalRewards[token][tokenId];
            if (historicalReward.amount > 0 && historicalReward.periodId < currentPeriod[token]) {
                hasReward = true;
                historicalRewards[token][tokenId].amount = 0;
                _safeTransferReward(token, msg.sender, historicalReward.amount, tokenId, historicalReward.periodId);
            }
        }
        
        if (!hasReward) revert NoRewards();
    }

    function _safeTransferReward(
        address token, 
        address to, 
        uint256 amount, 
        uint256 tokenId,
        uint256 periodId
    ) internal {
        if (amount == 0) return;
        
        // If token is locked token, auto-compound
        if (token == veSix.lockedToken()) {
            if (amount > type(uint128).max) revert("Amount too large");
            uint128 currentMultiplier = veSix.getCurrentMultiplier(tokenId);
            if (currentMultiplier == 0) revert("Invalid multiplier");
            IERC20Upgradeable(token).approve(address(veSix), amount);
            veSix.increaseLockAmount(
                tokenId, 
                uint128(amount), 
                block.timestamp, 
                currentMultiplier  // Use current multiplier as minimum
            );
            emit RewardPaid(tokenId, token, amount, periodId);
            return;
        }
        
        uint256 preBalance = IERC20Upgradeable(token).balanceOf(address(this));
        if (preBalance < amount) revert InsufficientBalance();
        
        uint256 recipientPreBalance = IERC20Upgradeable(token).balanceOf(to);
        
        IERC20Upgradeable(token).safeTransfer(to, amount);
        
        uint256 recipientPostBalance = IERC20Upgradeable(token).balanceOf(to);
        if (recipientPostBalance <= recipientPreBalance) revert TransferFailed();
        
        uint256 received = recipientPostBalance - recipientPreBalance;
        emit RewardPaid(tokenId, token, received, periodId);
    }

    function getClaimableRewards(uint256 tokenId) external view returns (
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory periods
    ) {
        try veSix.ownerOf(tokenId) returns (address owner) {
            if (owner == address(0)) revert InvalidState();
        } catch {
            revert InvalidState();
        }
        
        address[] memory allTokens = getRewardTokens();
        tokens = new address[](allTokens.length * 2); // *2 for active and historical
        amounts = new uint256[](allTokens.length * 2);
        periods = new uint256[](allTokens.length * 2);
        
        uint256 count;
        for(uint i = 0; i < allTokens.length; i++) {
            address token = allTokens[i];
            
            // Active rewards
            uint256 activeReward = earned(tokenId, token);
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
    
    

}

