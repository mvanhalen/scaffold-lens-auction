// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import {ERC2981CollectionRoyalties} from 'lens-modules/contracts/base/ERC2981CollectionRoyalties.sol';
import {Errors} from 'lens-modules/contracts/libraries/constants/Errors.sol';
import {ICollectNFT} from 'lens-modules/contracts/interfaces/ICollectNFT.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {ILensHub} from 'lens-modules/contracts/interfaces/ILensHub.sol';
import {LensBaseERC721} from 'lens-modules/contracts/base/LensBaseERC721.sol';
import {ActionRestricted} from 'lens-modules/contracts/modules/ActionRestricted.sol';
import {Strings} from '@openzeppelin/contracts/utils/Strings.sol';

/**
 * @title CustomCollectNFT
 * @author Paul Burke
 *
 * @dev This is a customizable CollectNFT, it differs from the v2 CollectNFT in that the the name and symbol can be set.
 */
contract CustomCollectNFT is LensBaseERC721, ERC2981CollectionRoyalties, ActionRestricted, ICollectNFT {
    using Strings for uint256;

    address public immutable HUB;

    uint256 internal _profileId;
    uint256 internal _pubId;
    uint256 internal _tokenIdCounter;

    bool private _initialized;
    string private _name;
    string private _symbol;
    uint16 private _royalty;

    uint256 internal _royaltiesInBasisPoints;

    constructor(address hub, address actionModule, string memory tokenName, string memory tokenSymbol, uint16 royalty) ActionRestricted(actionModule) {
        HUB = hub;
        _name = tokenName;
        _symbol = tokenSymbol;
        _royalty = royalty;
        _initialized = true;
    }

    /// @inheritdoc ICollectNFT
    function initialize(uint256 profileId, uint256 pubId) external override {
        if (_initialized) revert Errors.Initialized();
        _initialized = true;
        _setRoyalty(_royalty);
        _profileId = profileId;
        _pubId = pubId;
        // _name and _symbol remain uninitialized because we override the getters below
    }

    /// @inheritdoc ICollectNFT
    function mint(address to) external override onlyActionModule returns (uint256) {
        unchecked {
            uint256 tokenId = ++_tokenIdCounter;
            _mint(to, tokenId);
            return tokenId;
        }
    }

    /// @inheritdoc ICollectNFT
    function getSourcePublicationPointer() external view override returns (uint256, uint256) {
        return (_profileId, _pubId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) revert Errors.TokenDoesNotExist();
        return ILensHub(HUB).getContentURI(_profileId, _pubId);
    }

    /**
     * @dev See {IERC721Metadata-name}.
     */
    function name() public view override returns (string memory) {
        return bytes(_name).length > 0 ? _name : string.concat('Lens Collect | Profile #', _profileId.toString(), ' - Publication #', _pubId.toString());
    }

    /**
     * @dev See {IERC721Metadata-symbol}.
     */
    function symbol() public view override returns (string memory) {
        return bytes(_symbol).length > 0 ? _symbol : 'LENS-COLLECT';
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
    public
    view
    virtual
    override(ERC2981CollectionRoyalties, LensBaseERC721)
    returns (bool)
    {
        return
            ERC2981CollectionRoyalties.supportsInterface(interfaceId) || LensBaseERC721.supportsInterface(interfaceId);
    }

    function _getReceiver(
        uint256 /* tokenId */
    ) internal view override returns (address) {
        if (!ILensHub(HUB).exists(_profileId)) {
            return address(0);
        }
        return IERC721(HUB).ownerOf(_profileId);
    }

    function _beforeRoyaltiesSet(
        uint256 /* royaltiesInBasisPoints */
    ) internal view override {
        if (IERC721(HUB).ownerOf(_profileId) != msg.sender) {
            revert Errors.NotProfileOwner();
        }
    }

    function _getRoyaltiesInBasisPointsSlot() internal pure override returns (uint256) {
        uint256 slot;
        assembly {
            slot := _royaltiesInBasisPoints.slot
        }
        return slot;
    }
}
