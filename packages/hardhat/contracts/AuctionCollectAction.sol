// SPDX-License-Identifier:AGPL-3.0

pragma solidity 0.8.23;

import {IModuleRegistry} from "lens-modules/contracts/interfaces/IModuleRegistry.sol";
import {Types} from "lens-modules/contracts/libraries/constants/Types.sol";
import {Errors} from "lens-modules/contracts/libraries/constants/Errors.sol";
import {IPublicationActionModule} from "lens-modules/contracts/interfaces/IPublicationActionModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ILensGovernable} from "lens-modules/contracts/interfaces/ILensGovernable.sol";
import {LensModuleMetadata} from "lens-modules/contracts/modules/LensModuleMetadata.sol";
import {LensModuleRegistrant} from "lens-modules/contracts/modules/base/LensModuleRegistrant.sol";
import {HubRestricted} from "lens-modules/contracts/base/HubRestricted.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ICustomCollectNFT} from "./interfaces/ICustomCollectNFT.sol";
import {ILensProtocol} from "lens-modules/contracts/interfaces/ILensProtocol.sol";

/**
 * @notice A struct containing recipient data.
 *
 * @param recipient The recipient of the a % of auction's winner bid amount.
 * @param split The % of the winner bid amount fraction of BPS_MAX (10 000)
 */
struct RecipientData {
    address recipient;
    uint16 split;
}

/**
 * @notice A struct containing the necessary data to create an ERC-721.
 *
 * @param name The name of the token.
 * @param symbol The symbol of the token.
 * @param royalty The royalty percentage in basis points.
 */
struct TokenData {
    bytes32 name;
    bytes32 symbol;
    uint16 royalty;
}

/**
 * @notice A struct containing the necessary data to execute collect auctions.
 *
 * @param availableSinceTimestamp The UNIX timestamp after bids can start to be placed.
 * @param startTimestamp The UNIX timestamp of the first bid, i.e. when the auction started.
 * @param duration The seconds that the auction will last after the first bid has been placed.
 * @param minTimeAfterBid The minimum time, in seconds, that must always remain between last bid's timestamp
 * and `endTimestamp`. This restriction could make `endTimestamp` to be re-computed and updated.
 * @param endTimestamp The end of auction UNIX timestamp after which bidding is impossible. Computed inside contract.
 * @param reservePrice The minimum bid price accepted.
 * @param minBidIncrement The minimum amount by which a new bid must overcome the last bid.
 * @param winningBid The winning bid amount.
 * @param referralFee The percentage of the fee that will be transferred to the referrer in case of having one.
 * Measured in basis points, each basis point represents 0.01%.
 * @param currency The currency in which the bids are denominated.
 * @param winnerProfileId The current auction winner's profile ID.
 * @param onlyFollowers Indicates whether followers are the only allowed to bid, and collect, or not.
 * @param collected Indicates whether the publication has been collected or not.
 * @param feeProcessed Indicates whether the auction fee was already processed or not.
 * @param tokenData The data to create the ERC-721 token.
 */
struct AuctionData {
    uint64 availableSinceTimestamp;
    uint64 startTimestamp;
    uint32 duration;
    uint32 minTimeAfterBid;
    uint64 endTimestamp;
    uint256 reservePrice;
    uint256 minBidIncrement;
    uint256 winningBid;
    uint16 referralFee;
    address currency;
    uint256 winnerProfileId;
    bool onlyFollowers;
    bool collected;
    bool feeProcessed;
    TokenData tokenData;
}

struct InitAuctionData {
    uint64 availableSinceTimestamp;
    uint32 duration;
    uint32 minTimeAfterBid;
    uint256 reservePrice;
    uint256 minBidIncrement;
    uint16 referralFee;
    address currency;
    RecipientData[] recipients;
    bool onlyFollowers;
    bytes32 tokenName;
    bytes32 tokenSymbol;
    uint16 tokenRoyalty;
}

error ModuleDataMismatch();

/**
 * @title AuctionCollectActionModule
 * @author donosonaumczuk, Martijn van Halen and Paul Burke
 *
 * @notice This module works by creating an English auction for the underlying publication. After the auction ends, only
 * the auction winner is allowed to collect the publication.
 */
contract AuctionCollectAction is
    IPublicationActionModule,
    HubRestricted,
    LensModuleMetadata,
    LensModuleRegistrant
{
    using SafeERC20 for IERC20;
    uint16 internal constant BPS_MAX = 10000;

    error OngoingAuction();
    error UnavailableAuction();
    error CollectAlreadyProcessed();
    error FeeAlreadyProcessed();
    error InsufficientBidAmount();
    error TooManyRecipients();
    error InvalidRecipientSplits();
    error RecipientSplitCannotBeZero();

    event InitializedPublicationAction(
        uint256 profileId,
        uint256 pubId,
        address transactionExecutor,
        bytes data
    );

    event ProcessedPublicationAction(
        uint256 profileId,
        uint256 pubId,
        address transactionExecutor,
        bytes data
    );

    event AuctionCreated(
        uint256 indexed profileId,
        uint256 indexed pubId,
        uint64 availableSinceTimestamp,
        uint32 duration,
        uint32 minTimeAfterBid,
        uint256 reservePrice,
        uint256 minBidIncrement,
        uint16 referralFee,
        address currency,
        RecipientData[] recipients,
        bool onlyFollowers,
        bytes32 tokenName,
        bytes32 tokenSymbol,
        uint16 tokenRoyalty
    );

    event BidPlaced(
        uint256 indexed profileId,
        uint256 indexed pubId,
        uint256[] referrerProfileIds,
        uint256 amount,
        address bidderOwner,
        uint256 bidderProfileId,
        address transactionExecutor,
        uint256 endTimestamp,
        uint256 timestamp
    );

    event FeeProcessed(
        uint256 indexed profileId,
        uint256 indexed pubId,
        uint256 timestamp
    );

    /**
     * @dev Emitted when a collectNFT clone is deployed using a lazy deployment pattern.
     *
     * @param profileId The publisher's profile token ID.
     * @param pubId The publication associated with the newly deployed collectNFT clone's ID.
     * @param collectNFT The address of the newly deployed collectNFT clone.
     * @param timestamp The current block timestamp.
     */
    event CollectNFTDeployed(
        uint256 indexed profileId,
        uint256 indexed pubId,
        address indexed collectNFT,
        uint256 timestamp
    );

    /**
     * @dev Emitted upon a successful collect action.
     *
     * @param collectedProfileId The token ID of the profile that published the collected publication.
     * @param collectedPubId The ID of the collected publication.
     * @param collectorProfileId The token ID of the profile that collected the publication.
     * @param nftRecipient The address that received the collect NFT.
     * and depends on the collect module chosen.
     * @param collectNFT The address of the NFT collection where the minted collect NFT belongs to.
     * @param tokenId The token ID of the collect NFT that was minted as a collect of the publication.
     * @param timestamp The current block timestamp.
     */
    event Collected(
        uint256 indexed collectedProfileId,
        uint256 indexed collectedPubId,
        uint256 indexed collectorProfileId,
        address nftRecipient,
        address collectNFT,
        uint256 tokenId,
        uint256 timestamp
    );

    address private immutable TREASURY;
    address private immutable PROFILE_NFT;
    address private immutable LENS_PROTOCOL;

    address internal _collectNFTImpl;

    mapping(uint256 profileId => mapping(uint256 pubId => address collectNFT))
        internal _collectNFTByPub;

    mapping(uint256 profileId => mapping(uint256 pubId => AuctionData auctionData))
        internal _auctionDataByPubByProfile;

    mapping(uint256 profileId => mapping(uint256 pubId => RecipientData[] recipients))
        internal _recipientsByPublicationByProfile;

    /**
     * @dev Maps a given bidder's profile ID to its referrer profile IDs. Referrer matching publication's profile ID means
     * no referral, referrer being zero means that bidder has not bidded yet on this auction.
     * The referrer is set through, and only through, the first bidder's bid on each auction.
     */
    mapping(uint256 profileId => mapping(uint256 pubId => mapping(uint256 bidderProfileId => uint256[] referrerProfileIds)))
        internal _referrerProfileIdByPubByProfile;

    constructor(
        address hub,
        address treasury,
        address profileNFT,
        address lensProtocol,
        IModuleRegistry moduleRegistry,
        address collectNFTImpl
    )
        Ownable()
        HubRestricted(hub)
        LensModuleMetadata()
        LensModuleRegistrant(moduleRegistry)
    {
        TREASURY = treasury;
        PROFILE_NFT = profileNFT;
        LENS_PROTOCOL = lensProtocol;
        _collectNFTImpl = collectNFTImpl;
    }

    function getCollectNftImpl() external view returns (address) {
        return _collectNFTImpl;
    }

    function setCollectNftImpl(address _collectNftImpl) external onlyOwner {
        _collectNFTImpl = _collectNftImpl;
    }

    function supportsInterface(
        bytes4 interfaceID
    ) public pure virtual override returns (bool) {
        return
            interfaceID == type(IPublicationActionModule).interfaceId ||
            super.supportsInterface(interfaceID);
    }

    function _validateInitParams(InitAuctionData memory data) internal view {
        if (
            data.duration == 0 ||
            data.duration < data.minTimeAfterBid ||
            !MODULE_REGISTRY.isErc20CurrencyRegistered(data.currency) ||
            data.referralFee > BPS_MAX
        ) {
            revert Errors.InitParamsInvalid();
        }
    }

    function decodeInitParams(
        bytes calldata data
    ) internal pure returns (InitAuctionData memory) {
        (
            uint64 availableSinceTimestamp,
            uint32 duration,
            uint32 minTimeAfterBid,
            uint256 reservePrice,
            uint256 minBidIncrement,
            uint16 referralFee,
            address currency,
            RecipientData[] memory recipients,
            bool onlyFollowers,
            bytes32 tokenName,
            bytes32 tokenSymbol,
            uint16 tokenRoyalty
        ) = abi.decode(
                data,
                (
                    uint64,
                    uint32,
                    uint32,
                    uint256,
                    uint256,
                    uint16,
                    address,
                    RecipientData[],
                    bool,
                    bytes32,
                    bytes32,
                    uint16
                )
            );

        return
            InitAuctionData({
                availableSinceTimestamp: availableSinceTimestamp,
                duration: duration,
                minTimeAfterBid: minTimeAfterBid,
                reservePrice: reservePrice,
                minBidIncrement: minBidIncrement,
                referralFee: referralFee,
                currency: currency,
                recipients: recipients,
                onlyFollowers: onlyFollowers,
                tokenName: tokenName,
                tokenSymbol: tokenSymbol,
                tokenRoyalty: tokenRoyalty
            });
    }

    /**
     * @dev See `AuctionData` struct's natspec in order to understand `data` decoded values.
     *
     *
     */
    function initializePublicationAction(
        uint256 profileId,
        uint256 pubId,
        address transactionExecutor,
        bytes calldata data
    ) external override onlyHub returns (bytes memory) {
        emit InitializedPublicationAction(
            profileId,
            pubId,
            transactionExecutor,
            data
        );

        InitAuctionData memory initData = decodeInitParams(data);

        _validateInitParams(initData);
        _validateAndStoreRecipients(initData.recipients, profileId, pubId);

        _initAuction(profileId, pubId, initData);
        return data;
    }

    /**
     *  this open action makes the bid as gasless Open action
     *  params.actionModuleData contains amount The bid amount to offer.
     */
    function processPublicationAction(
        Types.ProcessActionParams calldata params
    ) external override onlyHub returns (bytes memory) {
        emit ProcessedPublicationAction(
            params.publicationActedProfileId,
            params.publicationActedId,
            params.transactionExecutor,
            params.actionModuleData
        );

        uint256 amount = abi.decode(params.actionModuleData, (uint256));

        _bid(
            params.publicationActedProfileId,
            params.publicationActedId,
            params.referrerProfileIds,
            amount,
            params.actorProfileOwner,
            params.actorProfileId,
            params.transactionExecutor
        );

        return params.actionModuleData;
    }

    /**
     * @notice If the given publication has an auction, this function returns all its information.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param pubId The publication ID associated with the underlying publication.
     *
     * @return The auction data for the given publication.
     */
    function getAuctionData(
        uint256 profileId,
        uint256 pubId
    ) external view returns (AuctionData memory) {
        return _auctionDataByPubByProfile[profileId][pubId];
    }

    // get recipients
    function getRecipients(
        uint256 profileId,
        uint256 pubId
    ) external view returns (RecipientData[] memory) {
        return _recipientsByPublicationByProfile[profileId][pubId];
    }

    function bytes32ToString(
        bytes32 _bytes32
    ) private pure returns (string memory) {
        bytes memory bytesArray = new bytes(32);
        for (uint256 i; i < 32; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }

    function _deployCollectNFT(
        uint256 profileId,
        uint256 pubId
    ) private returns (address) {
        address collectNFT = Clones.clone(_collectNFTImpl);
        AuctionData storage auction = _auctionDataByPubByProfile[profileId][
            pubId
        ];

        ICustomCollectNFT(collectNFT).initialize(
            profileId,
            pubId,
            bytes32ToString(auction.tokenData.name),
            bytes32ToString(auction.tokenData.symbol),
            auction.tokenData.royalty
        );
        emit CollectNFTDeployed(profileId, pubId, collectNFT, block.timestamp);

        return collectNFT;
    }

    function _getOrDeployCollectNFT(
        uint256 publicationCollectedProfileId,
        uint256 publicationCollectedId
    ) private returns (address) {
        address collectNFT = _collectNFTByPub[publicationCollectedProfileId][
            publicationCollectedId
        ];
        if (collectNFT == address(0)) {
            collectNFT = _deployCollectNFT(
                publicationCollectedProfileId,
                publicationCollectedId
            );
            _collectNFTByPub[publicationCollectedProfileId][
                publicationCollectedId
            ] = collectNFT;
        }
        return collectNFT;
    }

    function getCollectNFT(
        uint256 profileId,
        uint256 pubId
    ) external view returns (address) {
        return _collectNFTByPub[profileId][pubId];
    }

    /**
     *
     * @dev Process the collect by ensuring:
     *  1. Underlying publication's auction has finished.
     *  2. Parameters passed matches expected values (collector is the winner, correct referral info & no custom data).
     *  3. Publication has not been collected yet.
     * This function will also process collect fees if they have not been already processed through `processCollectFee`.
     */
    function claim(
        uint256 collectedProfileId,
        uint256 collectedPubId
    ) external {
        if (
            block.timestamp <
            _auctionDataByPubByProfile[collectedProfileId][collectedPubId]
                .availableSinceTimestamp
        ) {
            revert UnavailableAuction();
        }
        if (
            _auctionDataByPubByProfile[collectedProfileId][collectedPubId]
                .startTimestamp ==
            0 ||
            block.timestamp <=
            _auctionDataByPubByProfile[collectedProfileId][collectedPubId]
                .endTimestamp
        ) {
            revert OngoingAuction();
        }
        if (
            _auctionDataByPubByProfile[collectedProfileId][collectedPubId]
                .collected
        ) {
            revert CollectAlreadyProcessed();
        }

        uint256 winnerProfileId = _auctionDataByPubByProfile[
            collectedProfileId
        ][collectedPubId].winnerProfileId;
        address winnerAddress = IERC721(PROFILE_NFT).ownerOf(winnerProfileId);

        address collectNFT = _getOrDeployCollectNFT({
            publicationCollectedProfileId: collectedProfileId,
            publicationCollectedId: collectedPubId
        });

        uint256 tokenId = ICustomCollectNFT(collectNFT).mint(winnerAddress);

        _auctionDataByPubByProfile[collectedProfileId][collectedPubId]
            .collected = true;
        if (
            !_auctionDataByPubByProfile[collectedProfileId][collectedPubId]
                .feeProcessed
        ) {
            _processCollectFee(collectedProfileId, collectedPubId);
        }

        emit Collected({
            collectedProfileId: collectedProfileId,
            collectedPubId: collectedPubId,
            collectorProfileId: winnerProfileId,
            nftRecipient: winnerAddress,
            collectNFT: collectNFT,
            tokenId: tokenId,
            timestamp: block.timestamp
        });
    }

    /**
     * @notice Initializes the auction struct for the given publication.
     *
     * @dev Auction initialization logic moved to this function to avoid stack too deep error.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param pubId The publication ID associated with the underlying publication.
     * @param initData The auction initialization data.
     */
    function _initAuction(
        uint256 profileId,
        uint256 pubId,
        InitAuctionData memory initData
    ) internal {
        AuctionData storage auction = _auctionDataByPubByProfile[profileId][
            pubId
        ];
        auction.availableSinceTimestamp = initData.availableSinceTimestamp;
        auction.duration = initData.duration;
        auction.minTimeAfterBid = initData.minTimeAfterBid;
        auction.reservePrice = initData.reservePrice;
        auction.minBidIncrement = initData.minBidIncrement;
        auction.referralFee = initData.referralFee;
        auction.currency = initData.currency;
        auction.onlyFollowers = initData.onlyFollowers;
        auction.tokenData = TokenData(
            initData.tokenName,
            initData.tokenSymbol,
            initData.tokenRoyalty
        );

        emit AuctionCreated(
            profileId,
            pubId,
            initData.availableSinceTimestamp,
            initData.duration,
            initData.minTimeAfterBid,
            initData.reservePrice,
            initData.minBidIncrement,
            initData.referralFee,
            initData.currency,
            initData.recipients,
            initData.onlyFollowers,
            initData.tokenName,
            initData.tokenSymbol,
            initData.tokenRoyalty
        );
    }

    function _verifyErc20Currency(address currency) internal {
        if (currency != address(0)) {
            MODULE_REGISTRY.verifyErc20Currency(currency);
        }
    }

    function _treasuryData() internal view returns (address, uint16) {
        return ILensGovernable(TREASURY).getTreasuryData();
    }

    /**
     * @notice Process the fees from the given publication's underlying auction.
     *
     * @dev It delegates the fee processing to `_processCollectFeeWithoutReferral` or `_processCollectFeeWithReferral`
     * depending if has referrer or not.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param pubId The publication ID associated with the underlying publication.
     */
    function _processCollectFee(uint256 profileId, uint256 pubId) internal {
        _auctionDataByPubByProfile[profileId][pubId].feeProcessed = true;
        uint256[] storage referrerProfileIds = _referrerProfileIdByPubByProfile[
            profileId
        ][pubId][_auctionDataByPubByProfile[profileId][pubId].winnerProfileId];

        RecipientData[] memory recipients = _recipientsByPublicationByProfile[
            profileId
        ][pubId];
        if (
            referrerProfileIds.length == 0 || referrerProfileIds[0] == profileId
        ) {
            _processCollectFeeWithoutReferral(
                _auctionDataByPubByProfile[profileId][pubId].winningBid,
                _auctionDataByPubByProfile[profileId][pubId].currency,
                recipients
            );
        } else {
            _processCollectFeeWithReferral(
                _auctionDataByPubByProfile[profileId][pubId].winningBid,
                _auctionDataByPubByProfile[profileId][pubId].referralFee,
                referrerProfileIds,
                _auctionDataByPubByProfile[profileId][pubId].currency,
                recipients
            );
        }
        emit FeeProcessed(profileId, pubId, block.timestamp);
    }

    /**
     * @notice Process the fees sending the winner amount to the recipient.
     *
     * @param winnerBid The amount of the winner bid.
     * @param currency The currency in which the bids are denominated.
     * @param recipients The recipients of the auction's winner bid amount.
     */
    function _processCollectFeeWithoutReferral(
        uint256 winnerBid,
        address currency,
        RecipientData[] memory recipients
    ) internal {
        (address treasury, uint16 treasuryFee) = _treasuryData();

        uint256 treasuryAmount = (winnerBid * treasuryFee) / BPS_MAX;
        uint256 adjustedAmount = winnerBid - treasuryAmount;

        if (treasuryAmount > 0) {
            IERC20(currency).safeTransfer(treasury, treasuryAmount);
        }

        uint256 len = recipients.length;

        uint256 i;
        while (i < len) {
            uint256 amountForRecipient = (adjustedAmount *
                recipients[i].split) / BPS_MAX;
            if (amountForRecipient != 0)
                IERC20(currency).safeTransfer(
                    recipients[i].recipient,
                    amountForRecipient
                );
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Process the fees sending the winner amount to the recipient and the corresponding referral fee to the
     * owner of the referrer profile.
     *
     * @param winnerBid The amount of the winner bid.
     * @param referralFee The percentage of the fee that will be transferred to the referrer in case of having one.
     * Measured in basis points, each basis point represents 0.01%.
     * @param referrerProfileIds The token IDs of the referrers' profiles.
     * @param currency The currency in which the bids are denominated.
     * @param recipients The recipient of the auction's winner bid amount.
     */
    function _processCollectFeeWithReferral(
        uint256 winnerBid,
        uint16 referralFee,
        uint256[] storage referrerProfileIds,
        address currency,
        RecipientData[] memory recipients
    ) internal {
        (address treasury, uint16 treasuryFee) = _treasuryData();
        uint256 treasuryAmount = (winnerBid * treasuryFee) / BPS_MAX;
        uint256 adjustedAmount = winnerBid - treasuryAmount;

        if (treasuryAmount > 0) {
            IERC20(currency).safeTransfer(treasury, treasuryAmount);
        }

        uint256 totalReferralsAmount;
        if (referralFee > 0) {
            // The reason we levy the referral fee on the adjusted amount is so that referral fees
            // don't bypass the treasury fee, in essence referrals pay their fair share to the treasury.
            totalReferralsAmount = (adjustedAmount * referralFee) / BPS_MAX;
            uint256 numberOfReferrals = referrerProfileIds.length;
            uint256 amountPerReferral = totalReferralsAmount /
                numberOfReferrals;
            if (amountPerReferral > 0) {
                uint256 i;
                while (i < numberOfReferrals) {
                    address referralRecipient = IERC721(PROFILE_NFT).ownerOf(
                        referrerProfileIds[i]
                    );

                    // Send referral fee in ERC20 tokens
                    IERC20(currency).safeTransfer(
                        referralRecipient,
                        amountPerReferral
                    );
                    unchecked {
                        ++i;
                    }
                }
            }
        }

        adjustedAmount -= totalReferralsAmount;

        uint256 len = recipients.length;

        uint256 j;
        while (j < len) {
            uint256 amountForRecipient = (adjustedAmount *
                recipients[j].split) / BPS_MAX;
            if (amountForRecipient != 0)
                IERC20(currency).safeTransfer(
                    recipients[j].recipient,
                    amountForRecipient
                );
            unchecked {
                ++j;
            }
        }
    }

    /**
     * @notice Executes the given bid for the given auction. Each new successful bid transfers back the funds of the
     * previous winner and pulls funds from the new winning bidder.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param pubId The publication ID associated with the underlying publication.
     * @param referrerProfileIds The token IDs of the referrers' profiles.
     * @param amount The bid amount to offer.
     * @param bidderOwner The owner's address of the bidder profile.
     * @param bidderProfileId The token ID of the bidder profile
     * @param bidderTransactionExecutor The address executing the bid
     */
    function _bid(
        uint256 profileId,
        uint256 pubId,
        uint256[] memory referrerProfileIds,
        uint256 amount,
        address bidderOwner,
        uint256 bidderProfileId,
        address bidderTransactionExecutor
    ) internal {
        AuctionData memory auction = _auctionDataByPubByProfile[profileId][
            pubId
        ];
        _validateBid(profileId, amount, bidderProfileId, auction);
        _setReferrerProfileIdIfNotAlreadySet(
            profileId,
            pubId,
            referrerProfileIds,
            bidderProfileId
        );
        uint256 endTimestamp = _setNewAuctionStorageStateAfterBid(
            profileId,
            pubId,
            amount,
            bidderProfileId,
            auction
        );
        if (auction.winnerProfileId != 0) {
            address winnerAddress = IERC721(PROFILE_NFT).ownerOf(
                auction.winnerProfileId
            );
            IERC20(auction.currency).safeTransfer(
                winnerAddress,
                auction.winningBid
            );
        }
        IERC20(auction.currency).safeTransferFrom(
            bidderTransactionExecutor,
            address(this),
            amount
        );
        emit BidPlaced(
            profileId,
            pubId,
            _referrerProfileIdByPubByProfile[profileId][pubId][bidderProfileId],
            amount,
            bidderOwner,
            bidderProfileId,
            bidderTransactionExecutor,
            endTimestamp,
            block.timestamp
        );
    }

    function validateIsFollowingOrSelf(
        uint256 followerProfileId,
        uint256 followedProfileId
    ) private view {
        // We treat following yourself is always true
        if (followerProfileId == followedProfileId) {
            return;
        }
        if (
            !ILensProtocol(LENS_PROTOCOL).isFollowing(
                followerProfileId,
                followedProfileId
            )
        ) {
            revert Errors.NotFollowing();
        }
    }

    /**
     * @notice Validates if the given bid is valid for the given auction.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param amount The bid amount to offer.
     * @param bidderProfileId The token ID of the bidder profile.
     * @param auction The data of the auction where the bid is being placed.
     */
    function _validateBid(
        uint256 profileId,
        uint256 amount,
        uint256 bidderProfileId,
        AuctionData memory auction
    ) internal view {
        if (
            auction.duration == 0 ||
            block.timestamp < auction.availableSinceTimestamp ||
            (auction.startTimestamp > 0 &&
                block.timestamp > auction.endTimestamp)
        ) {
            revert UnavailableAuction();
        }

        _validateBidAmount(auction, amount);

        if (auction.onlyFollowers) {
            validateIsFollowingOrSelf(bidderProfileId, profileId);
        }
    }

    /**
     * @notice Updates the state of the auction data after a successful bid.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param pubId The publication ID associated with the underlying publication.
     * @param newWinningBid The amount of the new winning bid.
     * @param newWinnerProfileId The new winning bidder.
     * @param prevAuctionState The state of the auction data before the bid, which will be overrided.
     *
     * @return A UNIX timestamp representing the `endTimestamp` of the new auction state.
     */
    function _setNewAuctionStorageStateAfterBid(
        uint256 profileId,
        uint256 pubId,
        uint256 newWinningBid,
        uint256 newWinnerProfileId,
        AuctionData memory prevAuctionState
    ) internal returns (uint256) {
        AuctionData storage nextAuctionState = _auctionDataByPubByProfile[
            profileId
        ][pubId];
        nextAuctionState.winnerProfileId = newWinnerProfileId;
        nextAuctionState.winningBid = newWinningBid;
        uint256 endTimestamp = prevAuctionState.endTimestamp;
        if (prevAuctionState.winnerProfileId == 0) {
            endTimestamp = block.timestamp + prevAuctionState.duration;
            nextAuctionState.endTimestamp = uint64(endTimestamp);
            nextAuctionState.startTimestamp = uint64(block.timestamp);
        } else if (
            endTimestamp - block.timestamp < prevAuctionState.minTimeAfterBid
        ) {
            endTimestamp = block.timestamp + prevAuctionState.minTimeAfterBid;
            nextAuctionState.endTimestamp = uint64(endTimestamp);
        }
        return endTimestamp;
    }

    /**
     * @notice Sets the the given `referrerProfileId` if it is the first bid of the bidder, or returns the previously
     * set otherwise.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param pubId The publication ID associated with the underlying publication.
     * @param referrerProfileIds The token IDs of the referrers' profiles.
     * @param bidderProfileId The profile ID of the bidder whose referrer profile id is being set.
     */
    function _setReferrerProfileIdIfNotAlreadySet(
        uint256 profileId,
        uint256 pubId,
        uint256[] memory referrerProfileIds,
        uint256 bidderProfileId
    ) internal {
        uint256[]
            storage referrerProfileIdsSet = _referrerProfileIdByPubByProfile[
                profileId
            ][pubId][bidderProfileId];
        if (
            referrerProfileIdsSet.length == 0 || referrerProfileIdsSet[0] == 0
        ) {
            _referrerProfileIdByPubByProfile[profileId][pubId][
                bidderProfileId
            ] = referrerProfileIds;
        }
    }

    /**
     * @notice Checks if the given bid amount is valid for the given auction.
     *
     * @param auction The auction where the bid amount validation should be performed.
     * @param amount The bid amount to validate.
     */
    function _validateBidAmount(
        AuctionData memory auction,
        uint256 amount
    ) internal pure {
        bool auctionStartsWithCurrentBid = auction.winnerProfileId == 0;
        if (
            (auctionStartsWithCurrentBid && amount < auction.reservePrice) ||
            (!auctionStartsWithCurrentBid &&
                (amount <= auction.winningBid ||
                    (auction.minBidIncrement > 0 &&
                        amount - auction.winningBid < auction.minBidIncrement)))
        ) {
            revert InsufficientBidAmount();
        }
    }

    function _validateAndStoreRecipients(
        RecipientData[] memory recipients,
        uint256 profileId,
        uint256 pubId
    ) internal {
        uint256 len = recipients.length;

        // Check number of recipients is supported min 1 max 5
        if (len < 1) {
            revert Errors.InitParamsInvalid();
        }

        if (len > 5) {
            revert TooManyRecipients();
        }

        // Check recipient splits sum to 10 000 BPS (100%)
        uint256 totalSplits;
        uint256 i;
        while (i < len) {
            if (recipients[i].split == 0) revert RecipientSplitCannotBeZero();
            totalSplits += recipients[i].split;
            _recipientsByPublicationByProfile[profileId][pubId].push(
                recipients[i]
            );
            unchecked {
                ++i;
            }
        }

        if (totalSplits != BPS_MAX) {
            revert InvalidRecipientSplits();
        }
    }
}
