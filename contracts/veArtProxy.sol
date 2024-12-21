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
                '{"name": "veSIX #',
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
    
    function generateSVG(LockData memory data) internal pure returns (string memory) {
        string memory svg = string(
            abi.encodePacked(
                '<svg width="400" height="500" viewBox="0 0 400 500" fill="none" xmlns="http://www.w3.org/2000/svg">',
                _generateDefs(),
                _generateBackground(),
                _generateSonicWaves(),
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
                '<linearGradient id="bgGradient" x1="200" y1="0" x2="200" y2="500" gradientUnits="userSpaceOnUse">',
                '<stop offset="0%" stop-color="#1a237e"/>',
                '<stop offset="100%" stop-color="#000033"/>',
                '</linearGradient>',
                '<filter id="blur"><feGaussianBlur in="SourceGraphic" stdDeviation="5"/></filter>',
                '</defs>'
            )
        );
    }

    function _generateBackground() internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<rect width="400" height="500" rx="16" fill="url(#bgGradient)"/>'
            )
        );
    }

    function _generateSonicWaves() internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<g opacity="0.1" filter="url(#blur)">',
                '<path d="M50,250 Q200,150 350,250" stroke="white" stroke-width="2" fill="none"/>',
                '<path d="M50,270 Q200,170 350,270" stroke="white" stroke-width="2" fill="none"/>',
                '<path d="M50,290 Q200,190 350,290" stroke="white" stroke-width="2" fill="none"/>',
                '</g>'
            )
        );
    }

    function _generateContent(LockData memory data) internal pure returns (string memory) {
        string memory dateString = _formatDate(data.endTime);
        
        return string(
            abi.encodePacked(
                '<text x="50" y="80" fill="white" font-family="Arial" font-size="24" font-weight="bold">Sonic Index</text>',
                '<rect x="50" y="120" width="120" height="30" rx="4" fill="white" fill-opacity="0.1"/>',
                '<text x="60" y="140" fill="white" font-family="Arial" font-size="14">veSIX #',
                data.tokenId.toString(),
                '</text>',
                _generateLockInfo(data),
                _generateExpiryInfo(dateString)
            )
        );
    }

    function _generateLockInfo(LockData memory data) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<text x="50" y="200" fill="white" font-family="Arial" font-size="16">Amount Locked</text>',
                '<text x="50" y="230" fill="white" font-family="Arial" font-size="24">',
                uint256(data.amount / 1e18).toString(),
                '</text>',
                '<text x="250" y="200" fill="white" font-family="Arial" font-size="16">veSIX Power</text>',
                '<text x="250" y="230" fill="white" font-family="Arial" font-size="24">',
                uint256((data.multiplier * 100) / 1e20).toString(), // Divide by 1e20 to get 2 decimal places
                '</text>'
            )
        );
    }

    function _generateExpiryInfo(string memory dateString) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<text x="50" y="300" fill="white" font-family="Arial" font-size="16">Expires</text>',
                '<text x="50" y="330" fill="white" font-family="Arial" font-size="24">',
                dateString,
                '</text>'
            )
        );
    }

    function _formatDate(uint32 timestamp) internal pure returns (string memory) {
        uint256 day = (timestamp / 86400) % 31 + 1;
        uint256 month = (timestamp / 2629743) % 12 + 1;
        uint256 year = 1970 + (timestamp / 31556926);
        
        return string(
            abi.encodePacked(
                _padZero(day),
                '/',
                _padZero(month),
                '/',
                year.toString()
            )
        );
    }

    function _padZero(uint256 num) internal pure returns (string memory) {
        if (num < 10) {
            return string(
                abi.encodePacked(
                    '0',
                    num.toString()
                )
            );
        }
        return num.toString();
    }
}
