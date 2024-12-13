// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;


interface IRewardsDistributor {
    function claim(uint256 tokenId) external returns (uint256);
    function claimable(uint256 tokenId) external view returns (uint256);
    function checkpoint_token() external;
    function checkpoint_total_supply() external;
    function getRewardForDuration() external view returns (uint256);
}