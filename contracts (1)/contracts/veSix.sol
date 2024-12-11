// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IRewardDistributor.sol";

contract VeSix is ERC721, ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // Custom errors
    error InvalidAmount();
    error InvalidDuration();
    error TransferFailed();
    error NotTokenOwner();
    error LockNotExpired();
    error ZeroReward();
    error InvalidToken();
    error ZeroAddress();
    error DeadlineExpired();
    error ExceedsMaxLocks();
    error InvalidRewardRate();
    error SlippageExceeded();
    error MaxRewardRateExceeded();
    error InvalidSplitAmount();
    error TooManyPieces();
    error TokenNotExists();
    error LockNotExists();

    // Structs
    struct Point {
        int128 bias;    // Current farming power
        int128 slope;   // Farming power decrease rate
        uint32 ts;     // Timestamp of point
        uint32 blk;    // Block number
    }

    struct LockedBalance {
        int128 amount;
        uint32 end;
    }

    struct LockPosition {
        uint96 amount;
        uint32 endTime;
        uint32 lastUpdate;
        uint96 slope;
    }

     struct GlobalState {
        uint96 totalWeightedSupply;
        uint96 nextTokenId;
        uint32 epoch;
        bool emergencyMode;
    }

    // Constants
  uint32 private immutable MAXTIME = 180 days;
    uint32 private immutable WEEK = 7 * 86400;
    uint96 private immutable MAX_MULTIPLIER = 4e18;
    uint96 private immutable BASE_MULTIPLIER = 1e18;
    uint96 private immutable PRECISION = 1e18;
    uint16 private immutable MAX_LOCKS_PER_USER = 100;
    uint96 private immutable MAX_REWARD_RATE = 1000e18;
    int128 private immutable iMAXTIME;

    // State variables
    IERC20 private immutable i_lockedToken;
    IRewardsDistributor private immutable i_distributor;
    uint256 private _nextTokenId;
    
    // Point history state
    uint256 public epoch;
    mapping(uint256 => LockPosition) private _locks;
    mapping(address => uint16) private _userLockCount; // Changed to uint16
    mapping(uint256 => Point) public pointHistory;
    mapping(uint256 => uint32) public userPointEpoch; // Changed to uint32
    mapping(uint256 => mapping(uint32 => Point)) public userPointHistory; // Changed key to uint32
    mapping(uint256 => int128) public slopeChanges;
    uint96 private _totalWeightedSupply;

    // Emergency recovery
    address private immutable _emergencyRecoveryAddress;
    bool private _emergencyMode;

    // Events
    event Deposit(
        address indexed user, 
        uint256 indexed tokenId, 
        uint96 amount, 
        uint32 lockTime
    );
    event Withdraw(
        address indexed user, 
        uint256 indexed tokenId, 
        uint96 amount
    );
    event RewardClaimed(
        address indexed user, 
        uint256 indexed tokenId, 
        uint96 reward
    );
    event EmergencyModeEnabled(address recoveryAddress);
    event EmergencyWithdraw(
        address indexed user, 
        uint256 indexed tokenId, 
        uint96 amount
    );

     constructor(
        address lockedToken,
        address distributor,
        address emergencyRecovery,
        string memory name,
        string memory symbol
    ) ERC721(name, symbol) Ownable(msg.sender) {
        if (lockedToken == address(0) || 
            distributor == address(0) || 
            emergencyRecovery == address(0)) revert ZeroAddress();
            
        _pause();
        i_lockedToken = IERC20(lockedToken);
        i_distributor = IRewardsDistributor(distributor);
        _emergencyRecoveryAddress = emergencyRecovery;
        iMAXTIME = int128(uint128(MAXTIME));

        // Initialize point history
        pointHistory[0].blk = uint32(block.number);
        pointHistory[0].ts = uint32(block.timestamp);
    }

    // Modifiers
    modifier validDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    modifier checkRewardRate() {
        if (i_distributor.getRewardForDuration() > MAX_REWARD_RATE) 
            revert MaxRewardRateExceeded();
        _;
    }

// Break checkpoint into smaller functions
 function _checkpoint(
        uint256 tokenId,
        LockedBalance memory oldLocked,
        LockedBalance memory newLocked
    ) internal {
        Point memory lastPoint;
        uint32 timestamp = uint32(block.timestamp);
        uint32 blockNumber = uint32(block.number);
        
        if (_globalState.epoch > 0) {
            lastPoint = pointHistory[_globalState.epoch - 1];
        } else {
            lastPoint = Point({
                bias: 0,
                slope: 0,
                ts: timestamp,
                blk: blockNumber
            });
        }

        uint32 lastCheckpoint = lastPoint.ts;
        uint256 blockSlope;
        
        assembly {
            // Optimized timestamp comparison and slope calculation
            if gt(timestamp, lastPoint.ts) {
                blockSlope := div(
                    mul(PRECISION, sub(blockNumber, lastPoint.blk)),
                    sub(timestamp, lastPoint.ts)
                )
            }
        }

        // Process weekly checkpoints with optimized math
        lastPoint = _processWeeklyCheckpoints(
            lastPoint,
            lastCheckpoint,
            blockSlope,
            _globalState.epoch
        );

        unchecked {
            _globalState.epoch++;
        }

        if (tokenId != 0) {
            _checkpointToken(
                tokenId, 
                oldLocked, 
                newLocked,
                timestamp,
                blockNumber
            );
        }
    }

function _checkpointGlobal() internal returns (Point memory lastPoint) {
    uint256 _epoch = epoch;
    
    if (_epoch > 0) {
        lastPoint = pointHistory[_epoch - 1];
    } else {
        lastPoint = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });
    }

    uint256 lastCheckpoint = lastPoint.ts;
    uint256 blockSlope = 0;
    
    if (block.timestamp > lastPoint.ts) {
        blockSlope = (PRECISION * (block.number - lastPoint.blk)) / 
                    (block.timestamp - lastPoint.ts);
    }

    // Process weekly checkpoints
    lastPoint = _processWeeklyCheckpoints(
        lastPoint,
        lastCheckpoint,
        blockSlope,
        _epoch
    );

    epoch = _epoch;
    return lastPoint;
}

function _processWeeklyCheckpoints(
    Point memory lastPoint,
    uint256 lastCheckpoint,
    uint256 blockSlope,
    uint256 _epoch
) internal returns (Point memory) {
    Point memory initialLastPoint = lastPoint;
    uint256 ti = (lastCheckpoint / WEEK) * WEEK;
    
    for (uint256 i = 0; i < 255; ++i) {
        ti += WEEK;
        int128 dslope = 0;
        
        if (ti > block.timestamp) {
            ti = block.timestamp;
        } else {
            dslope = slopeChanges[ti];
        }
        
        lastPoint.bias -= lastPoint.slope * 
                         int128(int256(ti - lastCheckpoint));
        lastPoint.slope += dslope;
        lastPoint.ts = ti;
        lastPoint.blk = initialLastPoint.blk + 
                       (blockSlope * (ti - initialLastPoint.ts)) / PRECISION;
        
        if (ti == block.timestamp) {
            lastPoint.blk = block.number;
            break;
        } else {
            pointHistory[_epoch + 1 + i] = lastPoint;
        }
        
        lastCheckpoint = ti;
    }
    
    return lastPoint;
}

        function _checkpointToken(
        uint256 tokenId,
         LockedBalance memory oldLocked,
         LockedBalance memory newLocked
        ) internal {
             Point memory uOld;
             Point memory uNew;
    
    // Calculate old point values
    if (oldLocked.end > block.timestamp && oldLocked.amount > 0) {
        uOld.slope = oldLocked.amount / iMAXTIME;
        uOld.bias = uOld.slope * 
                    int128(int256(oldLocked.end - block.timestamp));
    }
    
    // Calculate new point values
    if (newLocked.end > block.timestamp && newLocked.amount > 0) {
        uNew.slope = newLocked.amount / iMAXTIME;
        uNew.bias = uNew.slope * 
                    int128(int256(newLocked.end - block.timestamp));
    }

    // Handle slope changes
    _processTokenSlopeChanges(
        oldLocked,
        newLocked,
        uOld.slope,
        uNew.slope
    );

    // Record user point history
    uint256 userEpoch = userPointEpoch[tokenId] + 1;
    userPointEpoch[tokenId] = userEpoch;
    uNew.ts = block.timestamp;
    uNew.blk = block.number;
    userPointHistory[tokenId][userEpoch] = uNew;
}

    function _processTokenSlopeChanges(
        LockedBalance memory oldLocked,
        LockedBalance memory newLocked,
        int128 oldSlope,
        int128 newSlope
    ) internal {
        // Schedule slope changes
        if (oldLocked.end > block.timestamp) {
            // oldDslope was <something> - u_old.slope, so we cancel that
            int128 oldDslope = slopeChanges[oldLocked.end];
            oldDslope += oldSlope;
            if (newLocked.end == oldLocked.end) {
                oldDslope -= newSlope;
            }
            slopeChanges[oldLocked.end] = oldDslope;
        }

        if (newLocked.end > block.timestamp) {
            if (newLocked.end > oldLocked.end) {
                int128 newDslope = slopeChanges[newLocked.end];
                newDslope -= newSlope;
                slopeChanges[newLocked.end] = newDslope;
            }
        }
}


    function createLock(
        uint96 amount,
        uint32 lockDuration,
        uint256 deadline,
        uint96 minMultiplier
    ) external nonReentrant whenNotPaused validDeadline(deadline) returns (uint256 tokenId) {
        if (amount == 0) revert InvalidAmount();
        if (lockDuration == 0 || lockDuration > MAXTIME) revert InvalidDuration();
        if (_userLockCount[msg.sender] >= MAX_LOCKS_PER_USER) revert ExceedsMaxLocks();
        
        uint32 unlockTime = uint32(block.timestamp) + lockDuration;
        
        // Calculate slope with safe math
        uint256 slopeCalc = (uint256(amount) * (MAX_MULTIPLIER - BASE_MULTIPLIER)) / MAXTIME;
        if (slopeCalc > type(uint96).max) revert InvalidAmount();
        uint96 slope = uint96(slopeCalc);
        
        // Verify minimum multiplier
        uint96 multiplier = uint96(BASE_MULTIPLIER + (uint256(slope) * lockDuration));
        if (multiplier < minMultiplier) revert SlippageExceeded();

        // Create new lock balance
        LockedBalance memory newLock = LockedBalance({
            amount: int128(uint128(amount)),
            end: unlockTime
        });
        
        // Checkpoint before modifying state
        _checkpoint(0, LockedBalance(0, 0), newLock);

        // Transfer tokens using SafeERC20
        uint256 balanceBefore = i_lockedToken.balanceOf(address(this));
        i_lockedToken.safeTransferFrom(msg.sender, address(this), amount);
        if (i_lockedToken.balanceOf(address(this)) != balanceBefore + amount) 
            revert TransferFailed();

        unchecked {
            tokenId = ++_nextTokenId;
            _userLockCount[msg.sender]++;
        }
        _safeMint(msg.sender, tokenId);

        _locks[tokenId] = LockPosition({
            amount: amount,
            endTime: unlockTime,
            lastUpdate: uint32(block.timestamp),
            slope: slope
        });

        uint256 weightedSupplyIncrease = (uint256(amount) * multiplier) / PRECISION;
        if (weightedSupplyIncrease > type(uint96).max) revert InvalidAmount();
        _totalWeightedSupply += uint96(weightedSupplyIncrease);

        emit Deposit(msg.sender, tokenId, amount, unlockTime);
    }
    function withdraw(uint256 tokenId) external nonReentrant {
    // Check if token exists first
    address owner = _ownerOf(tokenId);
    if (owner == address(0)) revert TokenNotExists();
    if (owner != msg.sender) revert NotTokenOwner();
    
    // Check if lock exists and get its data
    LockPosition memory lock = _locks[tokenId];
    if (lock.amount == 0) revert LockNotExists();
    if (block.timestamp < lock.endTime) revert LockNotExpired();
    
    uint96 amount = lock.amount;
    
    // Convert to LockedBalance for checkpoint
    LockedBalance memory oldLock = LockedBalance({
        amount: int128(uint128(amount)),
        end: lock.endTime
    });

    // Clear lock state first
    delete _locks[tokenId];
    
    // Calculate and subtract from weighted supply
    uint96 multiplier = getCurrentMultiplier(tokenId);
    uint256 weightedAmount = (uint256(amount) * multiplier) / PRECISION;
    _totalWeightedSupply -= uint96(weightedAmount);
    
    // Checkpoint after state updates
    _checkpoint(tokenId, oldLock, LockedBalance(0, 0));
    
    // Clean up user point history
    delete userPointEpoch[tokenId];
    
    // Burn token
    _burn(tokenId);
    unchecked {
        _userLockCount[msg.sender]--;
    }
    
    // Transfer tokens back to user
    i_lockedToken.safeTransfer(msg.sender, amount);
    
    emit Withdraw(msg.sender, tokenId, amount);
}
   
    function merge(
        uint256[] calldata tokenIds,
        uint256 deadline
    ) external nonReentrant whenNotPaused validDeadline(deadline) {
        if (tokenIds.length < 2) revert InvalidAmount();
        
        uint96 totalAmount;
        uint32 latestEndTime;
        
        // First pass: validate ownership and calculate totals
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (ownerOf(tokenIds[i]) != msg.sender) revert NotTokenOwner();
            
            LockPosition storage lock = _locks[tokenIds[i]];
            
            totalAmount += lock.amount;
            if (lock.endTime > latestEndTime) {
                latestEndTime = lock.endTime;
            }
        }
        
        // Create new merged position
        uint32 remainingDuration = latestEndTime - uint32(block.timestamp);
        if (remainingDuration > MAXTIME) revert InvalidDuration();
        
        uint256 slopeCalc = (uint256(totalAmount) * (MAX_MULTIPLIER - BASE_MULTIPLIER)) / MAXTIME;
        if (slopeCalc > type(uint96).max) revert InvalidAmount();
        uint96 newSlope = uint96(slopeCalc);
        
        // Mint new token
        uint256 newTokenId = ++_nextTokenId;
        _safeMint(msg.sender, newTokenId);
        
        // Checkpoint all old positions
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            LockPosition storage oldLock = _locks[tokenId];
            
            LockedBalance memory oldLockedBalance = LockedBalance({
                amount: int128(uint128(oldLock.amount)),
                end: oldLock.endTime
            });
            
            _checkpoint(tokenId, oldLockedBalance, LockedBalance(0, 0));
            delete _locks[tokenId];
            _burn(tokenId);
        }

        // Create new lock
        LockedBalance memory newLock = LockedBalance({
            amount: int128(uint128(totalAmount)),
            end: latestEndTime
        });
        
        _checkpoint(newTokenId, LockedBalance(0, 0), newLock);
        
        _locks[newTokenId] = LockPosition({
            amount: totalAmount,
            endTime: latestEndTime,
            lastUpdate: uint32(block.timestamp),
            slope: newSlope
        });

        unchecked {
            _userLockCount[msg.sender] = _userLockCount[msg.sender] - tokenIds.length + 1;
        }
        
        emit Deposit(msg.sender, newTokenId, totalAmount, latestEndTime);
    }

    function getFarmingPower(uint256 tokenId, uint256 timestamp) public view returns (uint256) {
        uint256 userEpoch = userPointEpoch[tokenId];
        if (userEpoch == 0) return 0;

        Point memory lastPoint = userPointHistory[tokenId][userEpoch];
        lastPoint.bias -= lastPoint.slope * int128(int256(timestamp - lastPoint.ts));
        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint256(uint128(lastPoint.bias));
    }

    function getTotalFarmingPower(uint256 timestamp) public view returns (uint256) {
        Point memory lastPoint = pointHistory[epoch];
        return _supplyAt(lastPoint, timestamp);
    }

    function _supplyAt(Point memory point, uint256 t) internal view returns (uint256) {
        Point memory lastPoint = point;
        uint256 ti = (lastPoint.ts / WEEK) * WEEK;
        for (uint256 i = 0; i < 255; ++i) {
            ti += WEEK;
            int128 dslope = 0;
            if (ti > t) {
                ti = t;
            } else {
                dslope = slopeChanges[ti];
            }
            lastPoint.bias -= lastPoint.slope * int128(int256(ti - lastPoint.ts));
            if (ti == t) {
                break;
            }
            lastPoint.slope += dslope;
            lastPoint.ts = ti;
        }

        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint256(uint128(lastPoint.bias));
    }

    // Emergency functions
    function enableEmergencyMode() external onlyOwner {
        _emergencyMode = true;
        _pause();
        emit EmergencyModeEnabled(_emergencyRecoveryAddress);
    }

    function emergencyWithdraw(uint256 tokenId) external nonReentrant {
        require(_emergencyMode, "Not in emergency mode");
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        
        LockPosition storage lock = _locks[tokenId];
        uint96 amount = lock.amount;
        
        delete _locks[tokenId];
        _burn(tokenId);
        unchecked {
            _userLockCount[msg.sender]--;
        }
        
        i_lockedToken.safeTransfer(msg.sender, amount);
        
        emit EmergencyWithdraw(msg.sender, tokenId, amount);
    }

    // View functions
    function getUserLockCount(address user) external view returns (uint256) {
        return _userLockCount[user];
    }

    function isEmergencyMode() external view returns (bool) {
        return _emergencyMode;
    }

    function totalWeightedSupply() external view returns (uint96) {
        return _totalWeightedSupply;
    }

    function getCurrentMultiplier(uint256 tokenId) public view returns (uint96) {
    LockPosition memory lock = _locks[tokenId];
    if (block.timestamp >= lock.endTime) return BASE_MULTIPLIER;
    
    uint256 timeLeft;
    unchecked {
        timeLeft = lock.endTime - block.timestamp;
    }
    return uint96(BASE_MULTIPLIER + (uint256(lock.slope) * timeLeft));
}
}