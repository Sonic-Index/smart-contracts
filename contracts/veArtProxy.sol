// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

interface IVeSix {
    function getCurrentMultiplier(uint256 tokenId) external view returns (uint128);
    function _locks(uint256 tokenId) external view returns (
        uint128 amount,
        uint128 slope,
        uint32 endTime,
        uint32 lastUpdate
    );
}

contract VeArtProxy is Ownable {
    using Strings for uint256;
    
    // Errors
    error InvalidTokenId();
    error ZeroAddress();
    
    // State variables
    IVeSix public immutable veSix;

    // Lock data struct to avoid stack too deep
    struct LockData {
        uint256 tokenId;
        uint128 amount;
        uint128 slope;
        uint32 endTime;
        uint32 lastUpdate;
        uint128 multiplier;
    }
    
    constructor(address _veSix) Ownable(msg.sender) {
        if (_veSix == address(0)) revert ZeroAddress();
        veSix = IVeSix(_veSix);
    }
    
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        LockData memory data = _getLockData(tokenId);
        string memory image = generateSVG(data);
        
        return string(
            abi.encodePacked(
                'data:application/json;base64,',
                Base64.encode(
                    bytes(_generateMetadata(data, image))
                )
            )
        );
    }

    function _getLockData(uint256 tokenId) internal view returns (LockData memory data) {
        (uint128 amount, uint128 slope, uint32 endTime, uint32 lastUpdate) = veSix._locks(tokenId);
        if (amount == 0) revert InvalidTokenId();
        
        data.tokenId = tokenId;
        data.amount = amount;
        data.slope = slope;
        data.endTime = endTime;
        data.lastUpdate = lastUpdate;
        data.multiplier = veSix.getCurrentMultiplier(tokenId);
    }

    function _generateMetadata(LockData memory data, string memory image) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '{"name": "veSix #',
                data.tokenId.toString(),
                '", "description": "Voting Escrow Position NFT", "image": "data:image/svg+xml;base64,',
                image,
                '", "attributes": [{"trait_type": "Amount", "value": "',
                uint256(data.amount / 1e18).toString(),
                '"}, {"trait_type": "Multiplier", "value": "',
                uint256((data.multiplier * 100) / 1e18).toString(),
                '%"}, {"trait_type": "Lock End", "value": "',
                uint256(data.endTime).toString(),
                '"}]}'
            )
        );
    }
    
    function generateSVG(LockData memory data) internal view returns (string memory) {
        string memory svg = string(
            abi.encodePacked(
                '<svg width="387" height="476" viewBox="0 0 387 476" fill="none" xmlns="http://www.w3.org/2000/svg">',
                _generateDefs(),
                _generateBackground(),
                _generateContent(data),
                '</svg>'
            )
        );
        return Base64.encode(bytes(svg));
    }

    function _generateDefs() internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<defs>',
                '<linearGradient id="paint0_linear_272_615" x1="193.5" y1="0" x2="193.5" y2="263" gradientUnits="userSpaceOnUse">',
                '<stop offset="0" stop-color="#4338CA"/>',
                '<stop offset="1" stop-color="#6366F1"/>',
                '</linearGradient>',
                '<clipPath id="clip0_272_615">',
                '<rect width="387" height="476" rx="16" fill="white"/>',
                '</clipPath>',
                '</defs>'
            )
        );
    }

    function _generateBackground() internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<g clip-path="url(#clip0_272_615)">',
                '<path d="M0 16C0 7.2 7.2 0 16 0H371C379.8 0 387 7.2 387 16V263H0V16Z" fill="url(#paint0_linear_272_615)"/>',
                '<path fill-rule="evenodd" clip-rule="evenodd" d="M0 263H387V460C387 468.8 379.8 476 371 476H16C7.2 476 0 468.8 0 460V263Z" fill="#01073A"/>',
                _generateDecorativePath(),
                '</g>'
            )
        );
    }

    function _generateDecorativePath() internal pure returns (string memory) {
        return '<path d="M93.1002 53.6C95.8002 49.3 97.8002 45.4 100.5 42C107.3 33.1 115.7 33.1 122.5 42C130 51.7 133.1 63.3 135.8 75C136.3 77.1 136.7 79.3 137.4 82.3C139.6 78.6 141.1 75.6 143.1 72.9C147.4 67.2 153.2 66.7 156.7 72.8C160.6 79.6 162.7 87.5 165.5 95C165.7 95.6 165.8 96.2 166.1 97.8C167.2 96 167.9 94.9 168.7 93.8C172.2 88.6 176.8 88.4 179.1 94.1C181.8 100.9 183.6 108.1 184.6 115.3C186.2 126.6 185.1 137.9 181.5 148.8C181.1 150 180.9 151.5 180.1 152.4C178.3 154.4 176.3 157.3 174.2 157.5C172.3 157.6 170.1 154.6 168.1 152.8C167.5 152.3 167.3 151.4 166.4 150C165 154.8 164.2 159.1 162.6 163C160.8 167.3 158.8 171.8 156 175.5C152.4 180.2 147.8 180 143.9 175.4C141.6 172.7 140 169.4 137.8 166C136.1 172.6 135.1 179.1 132.8 185.1C129.9 192.7 126.8 200.5 122.3 207.1C115.9 216.6 107.1 216.2 100.2 207C97.6001 203.5 95.6002 199.5 93.1002 195.5C90.8002 201.4 89.1002 207.3 86.3002 212.6C82.7002 219.5 78.8002 226.5 73.9002 232.5C62.6002 246.1 47.6002 245.8 36.0002 232.5C26.6002 221.8 21.1002 209 17.4002 195.5C3.70015 145.3 3.90015 95.2 19.7002 45.5C23.1002 34.7 28.2002 24.5 35.8002 15.9C47.7002 2.40002 62.4001 2.40002 74.2001 15.9C81.8001 24.6 86.5002 34.8 90.4002 45.5C91.4002 48 92.1002 50.5 93.1002 53.6Z" stroke="#BCC1F1" stroke-opacity="0.08" stroke-width="11"/>';
    }

    function _generateContent(LockData memory data) internal view returns (string memory) {
        return string(
            abi.encodePacked(
                _generateInfoBoxes(data),
                _generateLockPowerVisualization(data)
            )
        );
    }

    function _generateInfoBoxes(LockData memory data) internal view returns (string memory) {
        string memory tokenIdText = string(
            abi.encodePacked(
                '<rect x="24" y="287" width="174" height="30" rx="4" fill="#BDC2F3"/>',
                '<text x="40" y="305" fill="#01073A" font-family="monospace" font-size="14">Token ID: #',
                data.tokenId.toString(),
                '</text>'
            )
        );

        string memory amountText = string(
            abi.encodePacked(
                '<rect x="210" y="287" width="174" height="30" rx="4" fill="#BDC2F3"/>',
                '<text x="226" y="305" fill="#01073A" font-family="monospace" font-size="14">Amount: ',
                uint256(data.amount / 1e18).toString(),
                ' SIX</text>'
            )
        );

        uint256 remainingDays = (uint256(data.endTime) - block.timestamp) / 1 days;
        string memory timeText = string(
            abi.encodePacked(
                '<text x="40" y="385" fill="#BDC2F3" font-family="monospace" font-size="14">Time Remaining: ',
                remainingDays.toString(),
                ' days</text>'
            )
        );

        return string(abi.encodePacked(tokenIdText, amountText, timeText));
    }

    function _generateLockPowerVisualization(LockData memory data) internal pure returns (string memory) {
        uint256 visualHeight = (uint256(data.multiplier) * 200) / 1e18;
        
        return string(
            abi.encodePacked(
                '<g opacity="0.6">',
                '<ellipse cx="67.2" cy="119.5" rx="12.2" ry="',
                visualHeight.toString(),
                '" fill="#BDC2F3"/>',
                '</g>'
            )
        );
    }
}