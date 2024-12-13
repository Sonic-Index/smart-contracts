// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IVeSix.sol";



contract SixRewardsDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Events
    event RewardsDistributed(uint256 timestamp, uint256 amount);
    event RewardsClaimed(uint256 indexed tokenId, uint256 amount, uint256 currentEpoch, uint256 maxEpoch);
    
    // Constants
    uint256 private constant WEEK = 7 days;
    uint256 private constant MAX_REWARDS_DELAY = 7 days;

    // State variables
    IVeSix public immutable veSix;
    IERC20 public immutable rewardsToken;
    
    uint256 public startTime;
    uint256 public lastUpdateTime;
    uint256 public timeCursor;
    
    mapping(uint256 => uint256) public tokenTimeCursor;
    mapping(uint256 => uint256) public tokenEpoch;
    mapping(uint256 => uint256) public weeklyRewards;
    mapping(uint256 => uint256) public veSupplyCache;
    
    uint256 private rewardsBalance;

    // Errors
    error InvalidAddress();
    error RewardsNotReady();
    error NotAuthorized();
    error NoRewards();

    constructor(address _veSix, address _rewardsToken) Ownable(msg.sender) {
        if (_veSix == address(0) || _rewardsToken == address(0)) revert InvalidAddress();
        
        veSix = IVeSix(_veSix);
        rewardsToken = IERC20(_rewardsToken);
        
        startTime = (block.timestamp / WEEK) * WEEK;
        lastUpdateTime = startTime;
        timeCursor = startTime;
    }

    function distributeRewards() external nonReentrant {
        uint256 newRewards = rewardsToken.balanceOf(address(this)) - rewardsBalance;
        if (newRewards == 0) revert NoRewards();

        uint256 currentWeek = (block.timestamp / WEEK) * WEEK;
        uint256 weeksSinceUpdate = (currentWeek - lastUpdateTime) / WEEK;
        
        if (weeksSinceUpdate == 0) {
            // Add to current week if within same week
            weeklyRewards[currentWeek] += newRewards;
        } else {
            // Distribute evenly across missed weeks
            uint256 rewardsPerWeek = newRewards / weeksSinceUpdate;
            for (uint256 t = lastUpdateTime + WEEK; t <= currentWeek; t += WEEK) {
                weeklyRewards[t] += rewardsPerWeek;
            }
        }

        rewardsBalance += newRewards;
        lastUpdateTime = currentWeek;
        
        emit RewardsDistributed(block.timestamp, newRewards);
        
        _updateVeSupply();
    }

     function _updateVeSupply() internal {
        uint256 currentTime = (block.timestamp / WEEK) * WEEK;
        uint256 t = timeCursor;
        
        veSix.checkpoint();

        for (uint256 i = 0; i < 20 && t <= currentTime; i++) {
            uint256 epoch = _findEpochForTimestamp(t);
            IVeSix.Point memory point = veSix.point_history(epoch);
            
            int128 dt = 0;
            if (t > point.ts) {
                dt = int128(int256(t - point.ts));
            }
            
            int256 bias_slope_product = point.bias - point.slope * dt;
            veSupplyCache[t] = bias_slope_product > 0 ? uint256(bias_slope_product) : 0;
            
            t += WEEK;
    }
    
    timeCursor = t;
}

    function _findEpochForTimestamp(uint256 timestamp) internal view returns (uint256) {
        uint256 min = 0;
        uint256 max = veSix.epoch();
        
        for (uint256 i = 0; i < 128; i++) {
            if (min >= max) break;
            
            uint256 mid = (min + max + 2) / 2;
            IVeSix.Point memory point = veSix.point_history(mid);
            
            if (point.ts <= timestamp) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        
        return min;
    }

    function claimable(uint256 tokenId) external view returns (uint256) {
        uint256 currentWeek = (block.timestamp / WEEK) * WEEK;
        return _calculateClaim(tokenId, currentWeek);
    }

    function _calculateClaim(uint256 tokenId, uint256 maxTime) internal view returns (uint256) {
        uint256 userEpoch = tokenEpoch[tokenId];
        if (userEpoch == 0) userEpoch = 1;
        
        uint256 weekCursor = tokenTimeCursor[tokenId];
        if (weekCursor == 0) {
            IVeSix.Point memory userPoint = veSix.user_point_history(tokenId, userEpoch);
            weekCursor = ((userPoint.ts + WEEK - 1) / WEEK) * WEEK;
        }
        
        uint256 toDistribute;
        
        for (uint256 i = 0; i < 50 && weekCursor <= maxTime; i++) {
            uint256 balance = veSix.balanceOfNFTAt(tokenId, weekCursor);
            uint256 supply = veSupplyCache[weekCursor];
            
            if (balance > 0 && supply > 0 && weeklyRewards[weekCursor] > 0) {
                toDistribute += (balance * weeklyRewards[weekCursor]) / supply;
            }
            
            weekCursor += WEEK;
        }
        
        return toDistribute;
    }

    function claim(uint256 tokenId) external nonReentrant returns (uint256) {
        if (!veSix.isApprovedOrOwner(msg.sender, tokenId)) revert NotAuthorized();

        if (block.timestamp > timeCursor) {
            _updateVeSupply();
        }

        uint256 currentWeek = (block.timestamp / WEEK) * WEEK;
        uint256 amount = _calculateClaim(tokenId, currentWeek);
        if (amount == 0) revert NoRewards();

        // Update user state
        tokenTimeCursor[tokenId] = currentWeek;
        tokenEpoch[tokenId] = veSix.user_point_epoch(tokenId);
        
        // Update rewards balance
        rewardsBalance -= amount;
        
        // Transfer rewards
        address owner = veSix.ownerOf(tokenId);
        rewardsToken.safeTransfer(owner, amount);
        
        emit RewardsClaimed(tokenId, amount, tokenEpoch[tokenId], veSix.user_point_epoch(tokenId));
        
        return amount;
    }

    function claimMany(uint256[] calldata tokenIds) external nonReentrant returns (bool) {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (veSix.isApprovedOrOwner(msg.sender, tokenIds[i])) {
                try this.claim(tokenIds[i]) {} catch {}
            }
        }
        return true;
    }

    // View functions
    function getWeeklyRewards(uint256 timestamp) external view returns (uint256) {
        return weeklyRewards[(timestamp / WEEK) * WEEK];
    }

    function getCurrentVeSupply() external view returns (uint256) {
        uint256 currentWeek = (block.timestamp / WEEK) * WEEK;
        return veSupplyCache[currentWeek];
    }
}
