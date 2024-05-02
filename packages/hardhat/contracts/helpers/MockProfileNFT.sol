// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract MockProfileNFT is IERC721 {
    mapping(uint256 => address) private _owners;

    function mint(address to, uint256 tokenId) public {
        require(to != address(0), "ERC721: mint to the zero address");
        require(_owners[tokenId] == address(0), "ERC721: token already minted");

        _owners[tokenId] = to;

        emit Transfer(address(0), to, tokenId);
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        address owner = _owners[tokenId];
        require(
            owner != address(0),
            "ERC721: owner query for nonexistent token"
        );
        return owner;
    }

    // Other functions from IERC721 interface
    function balanceOf(address) public pure override returns (uint256 balance) {
        return 0;
    }
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) public virtual override {}
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override {}
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override {}
    function approve(address to, uint256 tokenId) public virtual override {}
    function setApprovalForAll(
        address operator,
        bool approved
    ) public virtual override {}
    function getApproved(
        uint256
    ) public view virtual override returns (address operator) {
        return address(0);
    }
    function isApprovedForAll(
        address,
        address
    ) public view virtual override returns (bool) {
        return false;
    }
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return interfaceId == type(IERC721).interfaceId;
    }
}
