// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ILensProtocol} from "lens-modules/contracts/interfaces/ILensProtocol.sol";
import {Types} from "lens-modules/contracts/libraries/constants/Types.sol";

contract MockLensProtocol is ILensProtocol {
    mapping(uint256 => mapping(uint256 => bool)) private _follows;

    function isFollowing(
        uint256 followerProfileId,
        uint256 followedProfileId
    ) external view override returns (bool) {
        return _follows[followerProfileId][followedProfileId];
    }

    function follow(
        uint256 followerProfileId,
        uint256[] calldata idsOfProfilesToFollow,
        uint256[] calldata /* followTokenIds */,
        bytes[] calldata /* datas */
    ) external override returns (uint256[] memory) {
        for (uint i = 0; i < idsOfProfilesToFollow.length; i++) {
            _follows[followerProfileId][idsOfProfilesToFollow[i]] = true;
        }

        // Return an empty array as this mock doesn't handle follow tokens
        return new uint256[](0);
    }

    // Other functions from ILensProtocol are left unimplemented
    function createProfile(
        Types.CreateProfileParams calldata createProfileParams
    ) external override returns (uint256) {}
    function setProfileMetadataURI(
        uint256 profileId,
        string calldata metadataURI
    ) external override {}
    function setProfileMetadataURIWithSig(
        uint256 profileId,
        string calldata metadataURI,
        Types.EIP712Signature calldata signature
    ) external override {}
    function setFollowModule(
        uint256 profileId,
        address followModule,
        bytes calldata followModuleInitData
    ) external override {}
    function setFollowModuleWithSig(
        uint256 profileId,
        address followModule,
        bytes calldata followModuleInitData,
        Types.EIP712Signature calldata signature
    ) external override {}
    function changeDelegatedExecutorsConfig(
        uint256 delegatorProfileId,
        address[] calldata delegatedExecutors,
        bool[] calldata approvals,
        uint64 configNumber,
        bool switchToGivenConfig
    ) external override {}
    function changeDelegatedExecutorsConfig(
        uint256 delegatorProfileId,
        address[] calldata delegatedExecutors,
        bool[] calldata approvals
    ) external override {}
    function changeDelegatedExecutorsConfigWithSig(
        uint256 delegatorProfileId,
        address[] calldata delegatedExecutors,
        bool[] calldata approvals,
        uint64 configNumber,
        bool switchToGivenConfig,
        Types.EIP712Signature calldata signature
    ) external override {}
    function post(
        Types.PostParams calldata postParams
    ) external override returns (uint256) {}
    function postWithSig(
        Types.PostParams calldata postParams,
        Types.EIP712Signature calldata signature
    ) external override returns (uint256) {}
    function comment(
        Types.CommentParams calldata commentParams
    ) external override returns (uint256) {}
    function commentWithSig(
        Types.CommentParams calldata commentParams,
        Types.EIP712Signature calldata signature
    ) external override returns (uint256) {}
    function mirror(
        Types.MirrorParams calldata mirrorParams
    ) external override returns (uint256) {}
    function mirrorWithSig(
        Types.MirrorParams calldata mirrorParams,
        Types.EIP712Signature calldata signature
    ) external override returns (uint256) {}
    function quote(
        Types.QuoteParams calldata quoteParams
    ) external override returns (uint256) {}
    function quoteWithSig(
        Types.QuoteParams calldata quoteParams,
        Types.EIP712Signature calldata signature
    ) external override returns (uint256) {}
    function followWithSig(
        uint256 followerProfileId,
        uint256[] calldata idsOfProfilesToFollow,
        uint256[] calldata followTokenIds,
        bytes[] calldata datas,
        Types.EIP712Signature calldata signature
    ) external override returns (uint256[] memory) {}
    function unfollow(
        uint256 unfollowerProfileId,
        uint256[] calldata idsOfProfilesToUnfollow
    ) external override {}
    function unfollowWithSig(
        uint256 unfollowerProfileId,
        uint256[] calldata idsOfProfilesToUnfollow,
        Types.EIP712Signature calldata signature
    ) external override {}
    function setBlockStatus(
        uint256 byProfileId,
        uint256[] calldata idsOfProfilesToSetBlockStatus,
        bool[] calldata blockStatus
    ) external override {}
    function setBlockStatusWithSig(
        uint256 byProfileId,
        uint256[] calldata idsOfProfilesToSetBlockStatus,
        bool[] calldata blockStatus,
        Types.EIP712Signature calldata signature
    ) external override {}
    function collectLegacy(
        Types.LegacyCollectParams calldata collectParams
    ) external override returns (uint256) {}
    function collectLegacyWithSig(
        Types.LegacyCollectParams calldata collectParams,
        Types.EIP712Signature calldata signature
    ) external override returns (uint256) {}
    function act(
        Types.PublicationActionParams calldata publicationActionParams
    ) external override returns (bytes memory) {}
    function actWithSig(
        Types.PublicationActionParams calldata publicationActionParams,
        Types.EIP712Signature calldata signature
    ) external override returns (bytes memory) {}
    function incrementNonce(uint8 increment) external override {}
    function isDelegatedExecutorApproved(
        uint256 delegatorProfileId,
        address delegatedExecutor,
        uint64 configNumber
    ) external view override returns (bool) {}
    function isDelegatedExecutorApproved(
        uint256 delegatorProfileId,
        address delegatedExecutor
    ) external view override returns (bool) {}
    function getDelegatedExecutorsConfigNumber(
        uint256 delegatorProfileId
    ) external view override returns (uint64) {}
    function getDelegatedExecutorsPrevConfigNumber(
        uint256 delegatorProfileId
    ) external view override returns (uint64) {}
    function getDelegatedExecutorsMaxConfigNumberSet(
        uint256 delegatorProfileId
    ) external view override returns (uint64) {}
    function isBlocked(
        uint256 profileId,
        uint256 byProfileId
    ) external view override returns (bool) {}
    function getContentURI(
        uint256 profileId,
        uint256 pubId
    ) external view override returns (string memory) {}
    function getProfile(
        uint256 profileId
    ) external view override returns (Types.Profile memory) {}
    function getPublication(
        uint256 profileId,
        uint256 pubId
    ) external view override returns (Types.PublicationMemory memory) {}
    function getPublicationType(
        uint256 profileId,
        uint256 pubId
    ) external view override returns (Types.PublicationType) {}
    function isActionModuleEnabledInPublication(
        uint256 profileId,
        uint256 pubId,
        address module
    ) external view override returns (bool) {}
}
