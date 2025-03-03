// SPDX-License-Identifier: MIT
//@author 0xPhant0m based on Andre Cronje's voteEscrow contract for Solidly

pragma solidity 0.8.27;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IRewardDistributor.sol";

contract VeSixUpgradeable is 
    ERC721Upgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable, 
    OwnableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Custom errors
    error InvalidAmount();
    error InvalidDuration();
    error TransferFailed();
    error NotTokenOwner();
    error LockNotExpired();
    error ZeroReward();
    error InvalidToken();
    error InvalidArtProxy(); 
    error ZeroAddress();
    error DeadlineExpired();
    error LockExpired();
    error ExceedsMaxLocks();
    error InvalidRewardRate();
    error SlippageExceeded();
    error MaxRewardRateExceeded();
    error TokenNotExists();
    error LockNotExists();
    error MultiplierTooHigh();
    error InvalidMultiplier();
    error ArithmeticError();


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
        uint128 slope;    
        uint32 endTime;
        uint32 lastUpdate;
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
    IERC20Upgradeable private _lockedToken;
    IRewardsDistributor private _distributor;
    
    
    uint32 private _nextTokenId;
    mapping(uint256 => LockPosition) public _locks; 
    mapping(address => uint8) public _userLockCount;
    
    // Point history state
    mapping(uint32 => Point) public pointHistory;
    uint32 public epoch;
    mapping(uint256 => uint32) public userPointEpoch;
    mapping(uint256 => mapping(uint32 => Point)) public userPointHistory;
    mapping(uint32 => int128) public slopeChanges;
    address public artProxy;
    uint32 MAX_BLOCK_DRIFT = 15;
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

    event LockExtended(
        address indexed user,
        uint256 indexed tokenId,
        uint32 newEndTime,
        uint128 newMultiplier
);

    event AmountIncreased(
        address indexed user,
        uint256 indexed tokenId,
        uint128 additionalAmount,
        uint128 newTotalAmount,
        uint128 newMultiplier
); 

    // Event to track point fixes
    event PointsFixed(uint256 indexed tokenId, uint32 fromEpoch, uint32 toEpoch);

    // Storage gap for future upgrades
    uint256[49] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address lockedToken_,
      
        address emergencyRecovery,
        string memory name,
        string memory symbol
    ) public initializer {
        if (lockedToken_ == address(0) || 

            emergencyRecovery == address(0)) revert ZeroAddress();
            
        __ERC721_init(name, symbol);
        __ReentrancyGuard_init();
        __Pausable_init();
        __Ownable_init(msg.sender);

        _pause();
        _lockedToken = IERC20Upgradeable(lockedToken_);
        _emergencyRecoveryAddress = emergencyRecovery;

        // Initialize point history
        pointHistory[0].blk = uint32(block.number);
        pointHistory[0].ts = uint32(block.timestamp);
    }

    function setDistributor(address distributor_) external onlyOwner {
        if (distributor_ == address(0)) revert ZeroAddress();
        if (address(_distributor) != address(0)) revert("Distributor already set");
        _distributor = IRewardsDistributor(distributor_);
    }

    // Modifiers
    modifier validDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }


    modifier poke(uint256 tokenId) {
        LockPosition memory lock = _locks[tokenId];
        if (lock.amount > 0 && uint32(block.timestamp) < lock.endTime) {
            // Calculate time-based parameters based on the corrected calculation
            uint32 timeLeft = lock.endTime - uint32(block.timestamp);
            
            // Get the current multiplier from the corrected algorithm
            uint256 timeRatio = (uint256(timeLeft) * PRECISION) / MAXTIME;
            uint256 multiplierCalc = BASE_MULTIPLIER + (uint256(MAX_MULTIPLIER - BASE_MULTIPLIER) * timeRatio) / PRECISION;
            uint128 newMultiplier = uint128(multiplierCalc);
            
            if (newMultiplier > MAX_MULTIPLIER) newMultiplier = MAX_MULTIPLIER;
            if (newMultiplier < BASE_MULTIPLIER) newMultiplier = BASE_MULTIPLIER;
            
            // Calculate proper slope based on the corrected calculation
            uint256 slopeCalc = (uint256(lock.amount) / MAXTIME) * PRECISION;
            uint128 newSlope = uint128(slopeCalc);
            
            // Only update if slope is different or it's been a while since last update
            if (lock.slope != newSlope || (block.timestamp - lock.lastUpdate) > 1 days) {
                // Record previous weighted supply value
                uint128 oldMultiplier;
                if (lock.slope > 0) {
                    uint256 oldTimeRatio = (uint256(timeLeft) * PRECISION) / MAXTIME;
                    uint256 oldMultiplierCalc = BASE_MULTIPLIER + (uint256(MAX_MULTIPLIER - BASE_MULTIPLIER) * oldTimeRatio) / PRECISION;
                    oldMultiplier = uint128(oldMultiplierCalc);
                    if (oldMultiplier > MAX_MULTIPLIER) oldMultiplier = MAX_MULTIPLIER;
                    if (oldMultiplier < BASE_MULTIPLIER) oldMultiplier = BASE_MULTIPLIER;
                } else {
                    oldMultiplier = BASE_MULTIPLIER;
                }
                
                uint256 oldWeightedAmount = (uint256(lock.amount) * oldMultiplier) / PRECISION;
                uint256 newWeightedAmount = (uint256(lock.amount) * newMultiplier) / PRECISION;
                
                // Update weighted supply by the difference
                if (newWeightedAmount > oldWeightedAmount) {
                    uint256 increase = newWeightedAmount - oldWeightedAmount;
                    _totalWeightedSupply += uint128(increase);
                } else if (oldWeightedAmount > newWeightedAmount) {
                    uint256 decrease = oldWeightedAmount - newWeightedAmount;
                    if (decrease > _totalWeightedSupply) {
                        _totalWeightedSupply = 0; // Safeguard against underflow
                    } else {
                        _totalWeightedSupply -= uint128(decrease);
                    }
                }
                
                // Checkpoint to record the update
                _checkpoint(
                    tokenId,
                    LockedBalance(int128(uint128(lock.amount)), lock.endTime),
                    LockedBalance(int128(uint128(lock.amount)), lock.endTime)
                );
                
                // Update lock parameters
                _locks[tokenId].slope = newSlope;
                _locks[tokenId].lastUpdate = uint32(block.timestamp);
            }
        }
        _;
    }

    function getCurrentMultiplier(uint256 tokenId) public view returns (uint128) {
        LockPosition memory lock = _locks[tokenId];
        if (uint32(block.timestamp) >= lock.endTime) return BASE_MULTIPLIER;
        
        // Calculate time-based multiplier - should be proportional to lock duration
        uint32 timeLeft = lock.endTime - uint32(block.timestamp);
        
        // Calculate how much of the maximum time is left (as a ratio)
        // This ensures amount doesn't affect multiplier, only duration does
        uint256 timeRatio = (uint256(timeLeft) * PRECISION) / MAXTIME;
        
        // Apply linear scaling between BASE_MULTIPLIER (1x) and MAX_MULTIPLIER (4x)
        uint256 multiplierCalc = BASE_MULTIPLIER + (uint256(MAX_MULTIPLIER - BASE_MULTIPLIER) * timeRatio) / PRECISION;
        
        uint128 multiplier = uint128(multiplierCalc);
        
        if (multiplier > MAX_MULTIPLIER) return MAX_MULTIPLIER;
        if (multiplier < BASE_MULTIPLIER) return BASE_MULTIPLIER;
        
        return multiplier;
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
        
        // Get the last point
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
        
        // Calculate block slope for time interpolation
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

        epoch = _epoch + 1;
        pointHistory[_epoch] = lastPoint;
        
        // Ensure we're not losing precision in the global state
        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
    }

    function _processWeeklyCheckpoints(
        Point memory lastPoint,
        uint32 lastCheckpoint,
        uint128 blockSlope,
        uint32 _epoch
    ) internal returns (Point memory) {
        uint32 ti = (lastCheckpoint / WEEK) * WEEK;
        uint32 t = uint32(block.timestamp);
        
        for (uint256 i = 0; i < 255;) {
            ti += WEEK;
            if (ti > t) {
                lastPoint.bias -= lastPoint.slope * int128(uint128(t - lastCheckpoint));
                lastPoint.ts = t;
                lastPoint.blk = uint32(block.number);
                break;
            }
            lastPoint.bias -= lastPoint.slope * int128(uint128(ti - lastCheckpoint));
            lastPoint.slope += slopeChanges[ti];
            lastPoint.ts = ti;
            lastPoint.blk = uint32(lastPoint.blk + (uint256(blockSlope) * (ti - lastPoint.ts)) / PRECISION);
            
            pointHistory[_epoch + 1 + uint32(i)] = lastPoint;
            lastCheckpoint = ti;
            unchecked { ++i; }
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
       
        _processLockPoint(oldLocked, uOld);
        _processLockPoint(newLocked, uNew);
        
        _processTokenSlopeChanges(oldLocked, newLocked, uOld.slope, uNew.slope);

        uint32 userEpoch = userPointEpoch[tokenId] + 1;
        userPointEpoch[tokenId] = userEpoch;
        uNew.ts = uint32(block.timestamp);
        uNew.blk = uint32(block.number);
        userPointHistory[tokenId][userEpoch] = uNew;
    }

    function _processLockPoint(
        LockedBalance memory locked,
        Point memory point
    ) internal view returns (bool) {
        if (locked.end <= uint32(block.timestamp) || locked.amount == 0) return false;
        
        uint256 timeLeft = uint256(locked.end - uint32(block.timestamp));
        timeLeft = timeLeft > MAXTIME ? MAXTIME : timeLeft;
        
        uint256 multiplier = BASE_MULTIPLIER + ((timeLeft * (MAX_MULTIPLIER - BASE_MULTIPLIER)) / MAXTIME);
        multiplier = multiplier > MAX_MULTIPLIER ? MAX_MULTIPLIER : 
                   multiplier < BASE_MULTIPLIER ? BASE_MULTIPLIER : multiplier;
        
        uint256 scaledAmount = uint256(uint128(locked.amount));
        point.bias = int128(uint128((scaledAmount * multiplier) / PRECISION));
        point.slope = int128(uint128((scaledAmount * PRECISION) / MAXTIME));
        
        return true;
    }

    function _processTokenSlopeChanges(
        LockedBalance memory oldLocked,
        LockedBalance memory newLocked,
        int128 oldSlope,
        int128 newSlope
    ) internal {
        // Handle old lock slope changes
        if (oldLocked.end > uint32(block.timestamp)) {
            // Remove the old slope change
            int128 oldDslope = slopeChanges[oldLocked.end];
            oldDslope += oldSlope;  // Add because we're removing negative slope
            
            // If the new lock ends at the same time, we need to account for its slope too
            if (newLocked.end == oldLocked.end) {
                oldDslope -= newSlope;  // Subtract new slope that will decrease at this time
            }
            
            slopeChanges[oldLocked.end] = oldDslope;
        }

        // Handle new lock slope changes
        if (newLocked.end > uint32(block.timestamp)) {
            if (newLocked.end > oldLocked.end) {
                // Only record new slope changes if the end time is different
                int128 newDslope = slopeChanges[newLocked.end];
                newDslope -= newSlope;  // This slope will decrease at the new end time
                slopeChanges[newLocked.end] = newDslope;
            }
        }
    }

    function _beforeTokenTransfer(
        address from,
        uint256 tokenId
    ) internal {
        
        if (from != address(0) && address(_distributor) != address(0) && _ownerOf(tokenId) != address(0)) {
            if (_distributor.earned(tokenId) > 0) {
                _distributor.claim(tokenId);
            }
        }
    }

     function transferFrom(address from, address to, uint256 tokenId) public virtual override {
        _beforeTokenTransfer(from, tokenId);
        super.transferFrom(from,to, tokenId);
     }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public virtual override {
         _beforeTokenTransfer(from, tokenId);
         super.safeTransferFrom(from, to, tokenId, data);
    }

    function withdraw(uint256 tokenId) external nonReentrant {
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) revert TokenNotExists();
        if (owner != msg.sender) revert NotTokenOwner();
        
        LockPosition memory lock = _locks[tokenId];
        if (lock.amount == 0) revert LockNotExists();
        if (uint32(block.timestamp) < lock.endTime) revert LockNotExpired();
        
        uint128 amount = lock.amount;
        
        // For expired locks, just subtract balance from weighted supply
        if (amount > _totalWeightedSupply) {
            _totalWeightedSupply = 0;
        } else {
            _totalWeightedSupply -= amount;
        }
        
        // Clear lock state
        delete _locks[tokenId];
        
        // Create checkpoint data
        LockedBalance memory oldLock = LockedBalance({
            amount: int128(uint128(amount)),
            end: lock.endTime
        });
        
        // Checkpoint after clearing lock
        _checkpoint(tokenId, oldLock, LockedBalance(0, 0));
        
        // Clean up remaining state
        delete userPointEpoch[tokenId];
        
        // Transfer tokens before burning NFT
        _lockedToken.safeTransfer(msg.sender, amount);
        
        // Burn NFT last
        _burn(tokenId);
        unchecked {
            _userLockCount[msg.sender]--;
        }
        
        emit Withdraw(msg.sender, tokenId, amount);
    }

    function _calculateLockParameters(
        uint128 amount,
        uint32 lockDuration,
        uint128 minMultiplier
    ) internal pure returns (uint128 slope, uint128 multiplier) {
        // First divide by MAXTIME to avoid overflow
        uint256 slopeCalc = uint256(amount) / MAXTIME;
        // Then multiply by PRECISION
        slopeCalc = slopeCalc * PRECISION;
        require(slopeCalc <= type(uint128).max, "Slope overflow");
        slope = uint128(slopeCalc);
        
        // Calculate multiplier
        multiplier = _calculateMultiplier(slope, lockDuration);
        
        if (multiplier > MAX_MULTIPLIER) revert MultiplierTooHigh();
        if (multiplier < minMultiplier) revert SlippageExceeded();
    }

    // Helper function to update weighted supply correctly for the poke operation
    // This is a differential update based on the change in multiplier
    function _updateWeightedSupply(uint256 tokenId, uint128 amount, uint128 newMultiplier) internal {
        // First calculate current weighted amount based on old multiplier
        // Since we don't store the old multiplier directly, we need to recalculate based on slope
        LockPosition memory lock = _locks[tokenId];
        uint128 oldMultiplier = lock.slope > 0 
            ? uint128(BASE_MULTIPLIER + (uint256(lock.slope) * (lock.endTime - uint32(block.timestamp))))
            : BASE_MULTIPLIER;
            
        if (oldMultiplier > MAX_MULTIPLIER) oldMultiplier = MAX_MULTIPLIER;
        if (oldMultiplier < BASE_MULTIPLIER) oldMultiplier = BASE_MULTIPLIER;
        
        // Calculate old and new weighted amounts
        uint256 oldWeightedAmount = (uint256(amount) * uint256(oldMultiplier)) / PRECISION;
        uint256 newWeightedAmount = (uint256(amount) * uint256(newMultiplier)) / PRECISION;
        
        // Calculate the difference (can be positive or negative)
        if (newWeightedAmount > oldWeightedAmount) {
            uint256 increase = newWeightedAmount - oldWeightedAmount;
            if (increase > type(uint128).max) revert ArithmeticError();
            _totalWeightedSupply += uint128(increase);
        } else if (oldWeightedAmount > newWeightedAmount) {
            uint256 decrease = oldWeightedAmount - newWeightedAmount;
            if (decrease > _totalWeightedSupply) {
                _totalWeightedSupply = 0; // Safeguard against underflow
            } else {
                _totalWeightedSupply -= uint128(decrease);
            }
        }
        // If equal, no change needed
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
        
        (uint128 slope, uint128 multiplier) = _calculateLockParameters(amount, lockDuration, minMultiplier);
        
        // Create new lock balance
        LockedBalance memory newLock = LockedBalance({
            amount: int128(uint128(amount)),
            end: unlockTime
        });
        
        // Checkpoint before modifying state
        _checkpoint(0, LockedBalance(0, 0), newLock);
        
        // Transfer tokens using SafeERC20
        uint256 balanceBefore = _lockedToken.balanceOf(address(this));
        _lockedToken.safeTransferFrom(msg.sender, address(this), amount);
        if (_lockedToken.balanceOf(address(this)) != balanceBefore + amount) 
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
        
        _updateWeightedSupply(tokenId, amount, multiplier);
        
        emit Deposit(msg.sender, tokenId, amount, unlockTime);
    }

    function extendLock(
        uint256 tokenId,
        uint32 additionalDuration,
        uint256 deadline,
        uint128 minMultiplier
    ) external nonReentrant whenNotPaused validDeadline(deadline) poke(tokenId) {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        
        LockPosition memory lock = _locks[tokenId];
        if (lock.amount == 0) revert LockNotExists();
        
        // Calculate new end time
        uint32 newEndTime = lock.endTime + additionalDuration;
        uint32 totalRemainingDuration = newEndTime - uint32(block.timestamp);
        if (totalRemainingDuration > MAXTIME) revert InvalidDuration();
        
        // Calculate new slope and multiplier with proper scaling
        uint128 newSlope = _calculateNewSlope(lock.amount);
        uint128 multiplier = _calculateMultiplier(newSlope, totalRemainingDuration);
        if (multiplier < minMultiplier) revert SlippageExceeded();
        
        // Update weighted supply
        _updateWeightedSupply(tokenId, lock.amount, multiplier);
        
        // Checkpoint
        _checkpoint(
            tokenId,
            LockedBalance({
                amount: int128(uint128(lock.amount)),
                end: lock.endTime
            }),
            LockedBalance({
                amount: int128(uint128(lock.amount)),
                end: newEndTime
            })
        );
        
        // Update lock state
        _locks[tokenId] = LockPosition({
            amount: lock.amount,
            endTime: newEndTime,
            lastUpdate: uint32(block.timestamp),
            slope: newSlope
        });
        
        emit LockExtended(msg.sender, tokenId, newEndTime, multiplier);
    }

    function _calculateNewSlope(uint128 amount) private pure returns (uint128) {
        // First divide by MAXTIME to avoid overflow
        uint256 slopeCalc = uint256(amount) / MAXTIME;
        // Then multiply by PRECISION
        slopeCalc = slopeCalc * PRECISION;
        require(slopeCalc <= type(uint128).max, "Slope too high");
        return uint128(slopeCalc);
    }

    function _calculateMultiplier(uint128 slope, uint32 duration) internal pure returns (uint128) {
        // Special case: If slope is 0, return base multiplier to avoid division by zero
        if (slope == 0) return BASE_MULTIPLIER;
        
        // Calculate time ratio first to avoid overflow
        uint256 timeRatio = (uint256(duration) * PRECISION) / MAXTIME;
        
        // Calculate multiplier based on time ratio
        uint256 multiplier = BASE_MULTIPLIER + 
            ((timeRatio * (MAX_MULTIPLIER - BASE_MULTIPLIER)) / PRECISION);
        
        if (multiplier > MAX_MULTIPLIER) return MAX_MULTIPLIER;
        if (multiplier < BASE_MULTIPLIER) return BASE_MULTIPLIER;
        
        return uint128(multiplier);
    }

    // Helper function for increasing lock amount logic
    function _processIncreaseLock(
        uint256 tokenId,
        uint128 additionalAmount,
        uint128 minMultiplier
    ) private {
        LockPosition storage lock = _locks[tokenId];
        
        // Get old values and calculate new values
        uint128 oldAmount = lock.amount;
        uint128 newAmount = oldAmount + additionalAmount;
        uint32 endTime = lock.endTime;
        uint32 remainingDuration = endTime - uint32(block.timestamp);
        
        // Calculate new slope and multiplier
        uint128 newSlope = _calculateNewSlope(newAmount);
        uint128 multiplier = _calculateMultiplier(newSlope, remainingDuration);
        
        // Get current multiplier and use higher value
        uint128 currentMultiplier = getCurrentMultiplier(tokenId);
        multiplier = multiplier > currentMultiplier ? multiplier : currentMultiplier;
        
        // Slippage check for non-dust amounts
        if (additionalAmount > PRECISION / 1000 && multiplier < minMultiplier) {
            revert SlippageExceeded();
        }
        
        // Checkpoint with correct LockedBalance structs
        _checkpoint(
            tokenId,
            LockedBalance({
                amount: int128(uint128(oldAmount)),
                end: endTime
            }),
            LockedBalance({
                amount: int128(uint128(newAmount)),
                end: endTime
            })
        );
        
        // Update lock state
        lock.amount = newAmount;
        lock.slope = newSlope;
        lock.lastUpdate = uint32(block.timestamp);
        
        // Update weighted supply
        _updateWeightedSupply(tokenId, additionalAmount, multiplier);
        
        emit AmountIncreased(msg.sender, tokenId, additionalAmount, newAmount, multiplier);
    }

    function increaseLockAmount(
        uint256 tokenId,
        uint128 additionalAmount,
        uint256 deadline,
        uint128 minMultiplier
    ) external nonReentrant whenNotPaused validDeadline(deadline) poke(tokenId) {
        // Basic validations
        if (ownerOf(tokenId) != tx.origin) 
        {if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();}
        if (additionalAmount == 0) revert InvalidAmount();
        
        // Check if lock exists and not expired
        LockPosition storage lock = _locks[tokenId];
        if (lock.amount == 0) revert LockNotExists();
        if (uint32(block.timestamp) >= lock.endTime) revert LockExpired();
        
        // Transfer tokens
        uint256 balanceBefore = _lockedToken.balanceOf(address(this));
        _lockedToken.safeTransferFrom(msg.sender, address(this), additionalAmount);
        if (_lockedToken.balanceOf(address(this)) != balanceBefore + additionalAmount)
            revert TransferFailed();
        
        // Process the lock increase in a separate function
        _processIncreaseLock(tokenId, additionalAmount, minMultiplier);
    }

    function getTotalFarmingPower(uint32 timestamp) public view returns (uint128) {
        Point memory lastPoint = pointHistory[epoch];
        return uint128(_supplyAt(lastPoint, timestamp));
    }

    function _supplyAt(Point memory point, uint32 t) internal view returns (uint128) {
        uint32 ti = (point.ts / WEEK) * WEEK;
        
        for (uint256 i = 0; i < 255;) {
            ti += WEEK;
            if (ti > t) {
                point.bias -= point.slope * int128(uint128(t - point.ts));
                break;
            }
            point.bias -= point.slope * int128(uint128(ti - point.ts));
            point.slope += slopeChanges[ti];
            point.ts = ti;
            unchecked { ++i; }
        }

        if (point.bias < 0) point.bias = 0;
        return uint128(uint256(uint128(point.bias)));
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
        
        // Use veRAM's approach for slope calculation
        uint128 newSlope = uint128((uint256(totalAmount) * PRECISION) / MAXTIME);
        
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
        
        LockPosition memory lock = _locks[tokenId];
        if (lock.amount == 0 || timestamp >= lock.endTime) return 0;

        for (uint32 i = userEpoch; i >= 1; i--) {
            Point memory point = userPointHistory[tokenId][i];
            if (point.ts <= timestamp) {
                uint256 timeRatio = (uint256(lock.endTime - timestamp) * PRECISION) / MAXTIME;
                uint256 multiplier = BASE_MULTIPLIER + ((timeRatio * (MAX_MULTIPLIER - BASE_MULTIPLIER)) / PRECISION);
                multiplier = multiplier > MAX_MULTIPLIER ? MAX_MULTIPLIER : 
                           multiplier < BASE_MULTIPLIER ? BASE_MULTIPLIER : multiplier;
                
                uint256 power = (uint256(uint128(point.bias)) * multiplier) / PRECISION;
                return power > type(uint128).max ? type(uint128).max : uint128(power);
            }
        }
        return 0;
    }

    function getExpectedMultiplier(uint128 amount, uint32 duration) public pure returns (uint128) {
        if (duration == 0 || duration > MAXTIME) revert InvalidDuration();
        if (amount == 0) revert InvalidAmount();
        
        // Combine _calculateNewSlope and _calculateMultiplier logic here
        uint256 slope = (uint256(amount) / MAXTIME) * PRECISION;
        if (slope == 0) return BASE_MULTIPLIER;
        
        uint256 timeRatio = (uint256(duration) * PRECISION) / MAXTIME;
        uint256 multiplier = BASE_MULTIPLIER + ((timeRatio * (MAX_MULTIPLIER - BASE_MULTIPLIER)) / PRECISION);
        
        return multiplier > MAX_MULTIPLIER ? MAX_MULTIPLIER : 
               multiplier < BASE_MULTIPLIER ? BASE_MULTIPLIER : uint128(multiplier);
    }

    // Remove redundant pokeLock function since _pokeLockImplementation exists
    function _pokeLockImplementation(uint256 tokenId) internal poke(tokenId) {
        // The poke modifier does all the work
    }

    // Simplify getMinMultiplier
    function getMinMultiplier(uint128 amount, uint32 lockDuration) public view returns (uint128) {
        uint32 minDuration = lockDuration > MAX_BLOCK_DRIFT ? lockDuration - MAX_BLOCK_DRIFT : lockDuration;
        return getExpectedMultiplier(amount, minDuration);
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
        
        _lockedToken.safeTransfer(msg.sender, amount);
        
        emit EmergencyWithdraw(msg.sender, tokenId, amount);
    }

    function unPause () external onlyOwner {
        _unpause();
    }

    // View functions
    function getUserLockCount(address user) external view returns (uint8) {
        return _userLockCount[user];
    }

    function lockedToken() external view returns (IERC20Upgradeable) { 
        return _lockedToken;
    }

    function isEmergencyMode() external view returns (bool) {
        return _emergencyMode;
    }

    function totalWeightedSupply() external view returns (uint128) {
        return _totalWeightedSupply;
    }

    function setArtProxy(address _artProxy) external onlyOwner {
    if (_artProxy == address(0)) revert ZeroAddress();
    artProxy = _artProxy;
}

    function tokensForOwner(address owner) external view returns(uint256[] memory tokenIds) {
        uint8 count = _userLockCount[owner];
        tokenIds = new uint256[](count);
        if (count == 0) return tokenIds;
        
        uint256 currentIndex = 0;
        for (uint256 id = 0; id < _nextTokenId; id++) {
            if (_ownerOf(id) == owner) {
                tokenIds[currentIndex] = id;
                currentIndex++;
                if (currentIndex >= count) break;
            }
        }
        
        return tokenIds;
    }

function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
    if (_ownerOf(tokenId) == address(0)) revert TokenNotExists();
    if (artProxy == address(0)) revert InvalidArtProxy();
    
    // Delegate tokenURI call to art proxy
    (bool success, bytes memory data) = artProxy.staticcall(
        abi.encodeWithSignature("tokenURI(uint256)", tokenId)
    );
    require(success, "Art proxy call failed");
    
    return abi.decode(data, (string));
}

function createLockFor(
    address recipient,
    uint128 amount,
    uint32 lockDuration,
    uint256 deadline,
    uint128 minMultiplier
) external nonReentrant whenNotPaused validDeadline(deadline) returns (uint256 tokenId) {
    if (amount == 0) revert InvalidAmount();
    if (lockDuration == 0 || lockDuration > MAXTIME) revert InvalidDuration();
    if (recipient == address(0)) revert ZeroAddress();
    if (_userLockCount[recipient] >= MAX_LOCKS_PER_USER) revert ExceedsMaxLocks();
    
    uint32 unlockTime = uint32(block.timestamp) + lockDuration;
    
    (uint128 slope, uint128 multiplier) = _calculateLockParameters(amount, lockDuration, minMultiplier);
    
    // Create new lock balance
    LockedBalance memory newLock = LockedBalance({
        amount: int128(uint128(amount)),
        end: unlockTime
    });
    
    // Checkpoint before modifying state
    _checkpoint(0, LockedBalance(0, 0), newLock);
    
    // Transfer tokens using SafeERC20
    uint256 balanceBefore = _lockedToken.balanceOf(address(this));
    _lockedToken.safeTransferFrom(msg.sender, address(this), amount);
    if (_lockedToken.balanceOf(address(this)) != balanceBefore + amount) 
        revert TransferFailed();
    
    unchecked {
        tokenId = _nextTokenId++;
        _userLockCount[recipient]++;
    }
    
    _safeMint(recipient, tokenId);
    
    _locks[tokenId] = LockPosition({
        amount: amount,
        endTime: unlockTime,
        lastUpdate: uint32(block.timestamp),
        slope: slope
    });
    
    _updateWeightedSupply(tokenId, amount, multiplier);
    
    emit Deposit(recipient, tokenId, amount, unlockTime);
}

    
function fixHistoricalPoints(uint256[] calldata tokenIds, uint256 batchSize) external {
    require(batchSize > 0 && batchSize <= 20, "Invalid batch size");
    
    for (uint256 i = 0; i < batchSize && i < tokenIds.length;) {
        uint256 tokenId = tokenIds[i];
        
        // Early returns for invalid cases
        if (_ownerOf(tokenId) == address(0) || userPointEpoch[tokenId] == 0) {
            unchecked { ++i; }
            continue;
        }

        LockPosition memory lock = _locks[tokenId];
        if (lock.amount == 0) {
            unchecked { ++i; }
            continue;
        }

        // Calculate base values once
        uint128 slope = uint128((lock.amount * PRECISION) / MAXTIME);
        uint32 userEpoch = userPointEpoch[tokenId];

        // Update points
        for (uint32 currentEpoch = 1; currentEpoch <= userEpoch;) {
            Point storage point = userPointHistory[tokenId][currentEpoch];
            if (point.ts == 0) {
                unchecked { ++currentEpoch; }
                continue;
            }

            // Calculate time-based multiplier
            uint32 timeLeft = lock.endTime > point.ts ? lock.endTime - point.ts : 0;
            timeLeft = timeLeft > MAXTIME ? MAXTIME : timeLeft;
            uint256 multiplier = BASE_MULTIPLIER + ((timeLeft * (MAX_MULTIPLIER - BASE_MULTIPLIER)) / MAXTIME);
            
            // Update point values
            point.slope = int128(slope);
            point.bias = int128(uint128((lock.amount * multiplier) / PRECISION));

            // Update slope changes for next point
            if (currentEpoch < userEpoch) {
                Point memory nextPoint = userPointHistory[tokenId][currentEpoch + 1];
                if (nextPoint.ts > 0) {
                    slopeChanges[nextPoint.ts] = nextPoint.slope - point.slope;
                }
            }
            
            unchecked { ++currentEpoch; }
        }
        
        unchecked { ++i; }
    }
}

}
