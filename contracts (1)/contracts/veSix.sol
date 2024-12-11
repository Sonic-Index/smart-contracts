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
    error TokenNotExists();
    error LockNotExists();

    struct Point {
        int128 bias;      // Current farming power
        int128 slope;     // Farming power decrease rate
        uint32 ts;        // Timestamp of point
        uint32 blk;       // Block number
    }

    struct LockedBalance {
        int128 amount;
        uint32 end;
    }

    struct LockPosition {
        uint128 amount;
        uint32 endTime;
        uint32 lastUpdate;
        uint128 slope;
    }

    // Constants
    uint32 private constant MAXTIME = 180 days;
    uint32 private constant WEEK = 7 * 86400;
    uint128 private constant MAX_MULTIPLIER = 4e18;
    uint128 private constant BASE_MULTIPLIER = 1e18;
    uint128 private constant PRECISION = 1e18;
    uint8 private constant MAX_LOCKS_PER_USER = 100;
    uint128 private constant MAX_REWARD_RATE = 1000e18;
    int128 private constant iMAXTIME = int128(uint128(MAXTIME));

    // State variables
    IERC20 private immutable i_lockedToken;
    IRewardsDistributor private immutable i_distributor;
    
    uint32 private _nextTokenId;
    mapping(uint256 => LockPosition) private _locks;
    mapping(address => uint8) private _userLockCount;
    
    // Point history state
    mapping(uint32 => Point) public pointHistory;
    uint32 public epoch;
    mapping(uint256 => uint32) public userPointEpoch;
    mapping(uint256 => mapping(uint32 => Point)) public userPointHistory;
    mapping(uint32 => int128) public slopeChanges;
    uint128 private _totalWeightedSupply;

    // Emergency recovery
    address private _emergencyRecoveryAddress;
    bool private _emergencyMode;

    // Events
    event Deposit(
        address indexed user, 
        uint256 indexed tokenId, 
        uint128 amount, 
        uint32 lockTime
    );
    event Withdraw(
        address indexed user, 
        uint256 indexed tokenId, 
        uint128 amount
    );
    event RewardClaimed(
        address indexed user, 
        uint256 indexed tokenId, 
        uint128 reward
    );
    event EmergencyModeEnabled(address recoveryAddress);
    event EmergencyWithdraw(
        address indexed user, 
        uint256 indexed tokenId, 
        uint128 amount
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

    function getCurrentMultiplier(uint256 tokenId) public view returns (uint128) {
        LockPosition memory lock = _locks[tokenId];
        if (uint32(block.timestamp) >= lock.endTime) return BASE_MULTIPLIER;
        
        uint32 timeLeft;
        unchecked {
            timeLeft = lock.endTime - uint32(block.timestamp);
        }
        return uint128(BASE_MULTIPLIER + (uint256(lock.slope) * timeLeft));
    }

    function _checkpoint(
        uint256 tokenId,
        LockedBalance memory oldLocked,
        LockedBalance memory newLocked
    ) internal {
        _checkpointGlobal();
        
        if (tokenId != 0) {
            _checkpointToken(
                tokenId, 
                oldLocked, 
                newLocked
            );
        }
    }

    function _checkpointGlobal() internal {
        uint32 _epoch = epoch;
        Point memory lastPoint;
        
        if (_epoch > 0) {
            lastPoint = pointHistory[_epoch - 1];
        } else {
            lastPoint = Point({
                bias: 0,
                slope: 0,
                ts: uint32(block.timestamp),
                blk: uint32(block.number)
            });
        }

        uint32 lastCheckpoint = lastPoint.ts;
        uint128 blockSlope = 0;
        
        if (uint32(block.timestamp) > lastCheckpoint) {
            blockSlope = uint128((PRECISION * (block.number - lastPoint.blk)) / 
                      (block.timestamp - lastPoint.ts));
        }

        // Process weekly checkpoints
        lastPoint = _processWeeklyCheckpoints(
            lastPoint,
            lastCheckpoint,
            blockSlope,
            _epoch
        );

        epoch = _epoch;
    }

    function _processWeeklyCheckpoints(
        Point memory lastPoint,
        uint32 lastCheckpoint,
        uint128 blockSlope,
        uint32 _epoch
    ) internal returns (Point memory) {
        Point memory initialLastPoint = lastPoint;
        uint32 ti = (lastCheckpoint / WEEK) * WEEK;
        
        for (uint256 i = 0; i < 255; ++i) {
            ti += WEEK;
            int128 dslope = 0;
            
            if (ti > uint32(block.timestamp)) {
                ti = uint32(block.timestamp);
            } else {
                dslope = slopeChanges[ti];
            }
            
            lastPoint.bias -= lastPoint.slope * int128(uint128(ti - lastCheckpoint));
            lastPoint.slope += dslope;
            lastPoint.ts = ti;
            lastPoint.blk = uint32(initialLastPoint.blk + 
                          (uint256(blockSlope) * (ti - initialLastPoint.ts)) / PRECISION);
            
            if (ti == uint32(block.timestamp)) {
                lastPoint.blk = uint32(block.number);
                break;
            } else {
                pointHistory[_epoch + 1 + uint32(i)] = lastPoint;
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
        
        if (oldLocked.end > uint32(block.timestamp) && oldLocked.amount > 0) {
            uOld.slope = oldLocked.amount / iMAXTIME;
            uOld.bias = uOld.slope * 
                       int128(uint128(oldLocked.end - uint32(block.timestamp)));
        }
        
        if (newLocked.end > uint32(block.timestamp) && newLocked.amount > 0) {
            uNew.slope = newLocked.amount / iMAXTIME;
            uNew.bias = uNew.slope * 
                       int128(uint128(newLocked.end - uint32(block.timestamp)));
        }

        _processTokenSlopeChanges(
            oldLocked,
            newLocked,
            uOld.slope,
            uNew.slope
        );

        uint32 userEpoch = userPointEpoch[tokenId] + 1;
        userPointEpoch[tokenId] = userEpoch;
        uNew.ts = uint32(block.timestamp);
        uNew.blk = uint32(block.number);
        userPointHistory[tokenId][userEpoch] = uNew;
    }

    function _processTokenSlopeChanges(
        LockedBalance memory oldLocked,
        LockedBalance memory newLocked,
        int128 oldSlope,
        int128 newSlope
    ) internal {
        if (oldLocked.end > uint32(block.timestamp)) {
            int128 oldDslope = slopeChanges[oldLocked.end];
            oldDslope += oldSlope;
            if (newLocked.end == oldLocked.end) {
                oldDslope -= newSlope;
            }
            slopeChanges[oldLocked.end] = oldDslope;
        }

        if (newLocked.end > uint32(block.timestamp)) {
            if (newLocked.end > oldLocked.end) {
                int128 newDslope = slopeChanges[newLocked.end];
                newDslope -= newSlope;
                slopeChanges[newLocked.end] = newDslope;
            }
        }
    }

    function withdraw(uint256 tokenId) external nonReentrant {
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) revert TokenNotExists();
        if (owner != msg.sender) revert NotTokenOwner();
        
        LockPosition memory lock = _locks[tokenId];
        if (lock.amount == 0) revert LockNotExists();
        if (uint32(block.timestamp) < lock.endTime) revert LockNotExpired();
        
        uint128 amount = lock.amount;
        
        LockedBalance memory oldLock = LockedBalance({
            amount: int128(uint128(amount)),
            end: lock.endTime
        });

        delete _locks[tokenId];
        
        uint128 multiplier = getCurrentMultiplier(tokenId);
        uint256 weightedAmount = (uint256(amount) * multiplier) / PRECISION;
        _totalWeightedSupply -= uint128(weightedAmount);
        
        _checkpoint(tokenId, oldLock, LockedBalance(0, 0));
        
        delete userPointEpoch[tokenId];
        
        _burn(tokenId);
        unchecked {
            _userLockCount[msg.sender]--;
        }
        
        i_lockedToken.safeTransfer(msg.sender, amount);
        
        emit Withdraw(msg.sender, tokenId, amount);
    }

    function getTotalFarmingPower(uint32 timestamp) public view returns (uint128) {
        Point memory lastPoint = pointHistory[epoch];
        return uint128(_supplyAt(lastPoint, timestamp));
    }

    function _supplyAt(Point memory point, uint32 t) internal view returns (uint128) {
        Point memory lastPoint = point;
        uint32 ti = (lastPoint.ts / WEEK) * WEEK;
        
        for (uint256 i = 0; i < 255; ++i) {
            ti += WEEK;
            int128 dslope = 0;
            if (ti > t) {
                ti = t;
            } else {
                dslope = slopeChanges[ti];
            }
            lastPoint.bias -= lastPoint.slope * int128(uint128(ti - lastPoint.ts));
            if (ti == t) {
                break;
            }
            lastPoint.slope += dslope;
            lastPoint.ts = ti;
        }

        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint128(uint256(uint128(lastPoint.bias)));
    }

function createLock(
        uint128 amount,
        uint32 lockDuration,
        uint256 deadline,
        uint128 minMultiplier
    ) external nonReentrant whenNotPaused validDeadline(deadline) returns (uint256 tokenId) {
        if (amount == 0) revert InvalidAmount();
        if (lockDuration == 0 || lockDuration > MAXTIME) revert InvalidDuration();
        if (_userLockCount[msg.sender] >= MAX_LOCKS_PER_USER) revert ExceedsMaxLocks();
        
        uint32 unlockTime = uint32(block.timestamp) + lockDuration;
        
        // Calculate slope with safe math
        uint256 slopeCalc = (uint256(amount) * (MAX_MULTIPLIER - BASE_MULTIPLIER)) / MAXTIME;
        if (slopeCalc > type(uint128).max) revert InvalidAmount();
        uint128 slope = uint128(slopeCalc);
        
        // Verify minimum multiplier
        uint128 multiplier = uint128(BASE_MULTIPLIER + (uint256(slope) * lockDuration));
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
            tokenId = _nextTokenId++;
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
        if (weightedSupplyIncrease > type(uint128).max) revert InvalidAmount();
        _totalWeightedSupply += uint128(weightedSupplyIncrease);

        emit Deposit(msg.sender, tokenId, amount, unlockTime);
    }

    function merge(
        uint256[] calldata tokenIds,
        uint256 deadline
    ) external nonReentrant whenNotPaused validDeadline(deadline) {
        if (tokenIds.length < 2) revert InvalidAmount();
        
        uint128 totalAmount;
        uint32 latestEndTime;
        
        // First pass: validate ownership and calculate totals
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (ownerOf(tokenIds[i]) != msg.sender) revert NotTokenOwner();
            
            LockPosition memory lock = _locks[tokenIds[i]];
            
            totalAmount += lock.amount;
            if (lock.endTime > latestEndTime) {
                latestEndTime = lock.endTime;
            }
        }
        
        // Create new merged position
        uint32 remainingDuration = latestEndTime - uint32(block.timestamp);
        if (remainingDuration > MAXTIME) revert InvalidDuration();
        
        uint256 slopeCalc = (uint256(totalAmount) * (MAX_MULTIPLIER - BASE_MULTIPLIER)) / MAXTIME;
        if (slopeCalc > type(uint128).max) revert InvalidAmount();
        uint128 newSlope = uint128(slopeCalc);
        
        uint256 newTokenId = ++_nextTokenId;
        _safeMint(msg.sender, newTokenId);
        
        // Checkpoint and cleanup old positions
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            LockPosition memory oldLock = _locks[tokenId];
            
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
            _userLockCount[msg.sender] = uint8(_userLockCount[msg.sender] - uint8(tokenIds.length) + 1);
        }
        
        emit Deposit(msg.sender, newTokenId, totalAmount, latestEndTime);
    }

    function getFarmingPower(uint256 tokenId, uint32 timestamp) public view returns (uint128) {
        uint32 userEpoch = userPointEpoch[tokenId];
        if (userEpoch == 0) return 0;

        Point memory lastPoint = userPointHistory[tokenId][userEpoch];
        lastPoint.bias -= lastPoint.slope * int128(uint128(timestamp - lastPoint.ts));
        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint128(uint256(uint128(lastPoint.bias)));
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
        
        LockPosition memory lock = _locks[tokenId];
        uint128 amount = lock.amount;
        
        delete _locks[tokenId];
        _burn(tokenId);
        unchecked {
            _userLockCount[msg.sender]--;
        }
        
        i_lockedToken.safeTransfer(msg.sender, amount);
        
        emit EmergencyWithdraw(msg.sender, tokenId, amount);
    }

    // View functions
    function getUserLockCount(address user) external view returns (uint8) {
        return _userLockCount[user];
    }

    function isEmergencyMode() external view returns (bool) {
        return _emergencyMode;
    }

    function totalWeightedSupply() external view returns (uint128) {
        return _totalWeightedSupply;
    }
}
    
