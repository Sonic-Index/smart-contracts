// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

interface IVeSix {
    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }
    
    function balanceOfNFTAt(uint256 tokenId, uint256 timestamp) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool);
    function lockedToken() external view returns (address);
    function increaseLockAmount(uint256 tokenId, uint128 additionalAmount, uint256 deadline,
     uint128 minMultiplier) external;
    function getCurrentMultiplier(uint256 tokenId) external view returns (uint128);
    function deposit_for(uint256 tokenId, uint256 value) external;
    function point_history(uint256 epoch) external view returns (Point memory);
    function user_point_history(uint256 tokenId, uint256 loc) external view returns (Point memory);
    function epoch() external view returns (uint256);
    function user_point_epoch(uint256 tokenId) external view returns (uint256);
    function checkpoint() external;
}
