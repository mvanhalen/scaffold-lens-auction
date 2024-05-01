// SPDX-License-Identifier:AGPL-3.0

pragma solidity 0.8.23;

import {IModuleRegistry} from "lens-modules/contracts/interfaces/IModuleRegistry.sol";
import {Types} from "lens-modules/contracts/libraries/constants/Types.sol";
import {Errors} from "lens-modules/contracts/libraries/constants/Errors.sol";
import {IPublicationActionModule} from "lens-modules/contracts/interfaces/IPublicationActionModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Timestamped} from "lens-modules/contracts/interfaces/IERC721Timestamped.sol";
import {ILensGovernable} from "lens-modules/contracts/interfaces/ILensGovernable.sol";
import {LensModule} from "lens-modules/contracts/modules/LensModule.sol";
import {LensModuleMetadata} from "lens-modules/contracts/modules/LensModuleMetadata.sol";
import {LensModuleRegistrant} from "lens-modules/contracts/modules/base/LensModuleRegistrant.sol";
import {HubRestricted} from "lens-modules/contracts/base/HubRestricted.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ModuleTypes} from "lens-modules/contracts/modules/libraries/constants/ModuleTypes.sol";
import {FollowValidationLib} from "lens-modules/contracts/modules/libraries/FollowValidationLib.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ICustomCollectNFT} from "./interfaces/ICustomCollectNFT.sol";


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
 * @notice A struct containing winner data.
 *
 * @param profileId The token ID of the profile that is winning the auction.
 * @param profileOwner The owner's address of the profile that is winning the auction.
 * @param transactionExecutor The address executing the bid.
 */
struct Winner {
    uint256 profileId;
    address profileOwner;
    address transactionExecutor;
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
 * @param recipient The recipient of the auction's winner bid amount.
 * @param winner The current auction winner.
 * @param onlyFollowers Indicates whether followers are the only allowed to bid, and collect, or not.
 * @param collected Indicates whether the publication has been collected or not.
 * @param feeProcessed Indicates whether the auction fee was already processed or not.
 * @param tokenData The data to create the ERC-721 token.
 */
struct AuctionData {
    uint256 availableSinceTimestamp;
    uint64 startTimestamp;
    uint32 duration;
    uint32 minTimeAfterBid;
    uint64 endTimestamp;
    uint256 reservePrice;
    uint256 minBidIncrement;
    uint256 winningBid;
    uint16 referralFee;
    address currency;
    Winner winner;
    bool onlyFollowers;
    bool collected;
    bool feeProcessed;
    TokenData tokenData;
}

struct InitAuctionData {
    uint256 availableSinceTimestamp;
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
 * @author Lens Protocol, Martijn van Halen and Paul Burke
 *
 * @notice This module works by creating an English auction for the underlying publication. After the auction ends, only
 * the auction winner is allowed to collect the publication.
 */
contract AuctionActionModule is
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
        uint256 availableSinceTimestamp,
        uint32 duration,
        uint32 minTimeAfterBid,
        uint256 reservePrice,
        uint256 minBidIncrement,
        uint16 referralFee,
        address currency,
        bool onlyFollowers,
        bytes32 tokenName,
        bytes32 tokenSymbol,
        uint16 tokenRoyalty
    );

    event BidPlaced(
        uint256 indexed profileId,
        uint256 indexed pubId,
        uint256 referrerProfileId,
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

    address public immutable COLLECT_NFT_IMPL;
    address public immutable TREASURY;

    mapping(uint256 profileId => mapping(uint256 pubId => address collectNFT))
        internal _collectNFTByPub;

    mapping(uint256 => mapping(uint256 => AuctionData))
        internal _auctionDataByPubByProfile;

    mapping(uint256 => mapping(uint256 => RecipientData[])) 
        internal _recipientsByPubByProfile;

    /**
     * @dev Maps a given bidder's address to its referrer profile ID. Referrer matching publication's profile ID means
     * no referral, referrer being zero means that bidder has not bidded yet on this auction.
     * The referrer is set through, and only through, the first bidder's bid on each auction.
     */
    mapping(uint256 => mapping(uint256 => mapping(address => uint256)))
        internal _referrerProfileIdByPubByProfile;

    constructor(
        address hub,
        address treasury,
        IModuleRegistry moduleRegistry,
        address collectNFTImpl
    )
        Ownable()
        HubRestricted(hub)
        LensModuleMetadata()
        LensModuleRegistrant(moduleRegistry)
    {
        TREASURY = treasury;
        COLLECT_NFT_IMPL = collectNFTImpl;
    }

    function supportsInterface(
        bytes4 interfaceID
    ) public pure virtual override returns (bool) {
        return
            interfaceID == type(IPublicationActionModule).interfaceId ||
            super.supportsInterface(interfaceID);
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

        InitAuctionData memory initData = abi.decode(data, (InitAuctionData));

        if (
            initData.duration == 0 ||
            initData.duration < initData.minTimeAfterBid ||
            !MODULE_REGISTRY.isErc20CurrencyRegistered(initData.currency) ||
            initData.referralFee > BPS_MAX
        ) {
            revert Errors.InitParamsInvalid();
        }

        _initAuction(profileId, pubId, initData);
        return data;
    }

    /**
     *  this open action makes the bid as gasless Open action
     *  params.actionModuleData contains amount The bid amount to offer.
     *  bidderProfileId The token ID of the bidder profile.
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

        (uint256 amount, uint256 bidderProfileId) = abi.decode(
            params.actionModuleData,
            (uint256, uint256)
        );

        _bid(
            params.publicationActedProfileId,
            params.publicationActedId,
            params.publicationActedProfileId,
            amount,
            params.actorProfileOwner,
            bidderProfileId,
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

    function bytes32ToString(
        bytes32 _bytes32
    ) public pure returns (string memory) {
        bytes memory bytesArray = new bytes(32);
        for (uint256 i; i < 32; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }

    function _deployCollectNFT(
        uint256 profileId,
        uint256 pubId,
        address collectNFTImpl
    ) private returns (address) {
        address collectNFT = Clones.clone(collectNFTImpl);
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
        uint256 publicationCollectedId,
        address collectNFTImpl
    ) private returns (address) {
        address collectNFT = _collectNFTByPub[publicationCollectedProfileId][
            publicationCollectedId
        ];
        if (collectNFT == address(0)) {
            collectNFT = _deployCollectNFT(
                publicationCollectedProfileId,
                publicationCollectedId,
                collectNFTImpl
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

        Winner storage winner = _auctionDataByPubByProfile[collectedProfileId][
            collectedPubId
        ].winner;

        address collectNFT = _getOrDeployCollectNFT({
            publicationCollectedProfileId: collectedProfileId,
            publicationCollectedId: collectedPubId,
            collectNFTImpl: COLLECT_NFT_IMPL
        });

        uint256 tokenId = ICustomCollectNFT(collectNFT).mint(
            winner.profileOwner
        );

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
            collectorProfileId: winner.profileId,
            nftRecipient: winner.profileOwner,
            collectNFT: collectNFT,
            tokenId: tokenId,
            timestamp: block.timestamp
        });
    }

    /**
     * @notice Processes the collect fees using the auction winning bid funds and taking into account referrer and
     * treasury fees if necessary.
     *
     * @dev This function allows anyone to process the collect fees, not needing to wait for `processCollect` to be
     * called, as long as the auction has finished, has a winner and the publication has not been collected yet.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param pubId The publication ID associated with the underlying publication.
     */
    function processCollectFee(uint256 profileId, uint256 pubId) external {
        if (
            _auctionDataByPubByProfile[profileId][pubId].duration == 0 ||
            block.timestamp <
            _auctionDataByPubByProfile[profileId][pubId].availableSinceTimestamp
        ) {
            revert UnavailableAuction();
        }
        if (
            _auctionDataByPubByProfile[profileId][pubId].startTimestamp == 0 ||
            block.timestamp <=
            _auctionDataByPubByProfile[profileId][pubId].endTimestamp
        ) {
            revert OngoingAuction();
        }
        if (_auctionDataByPubByProfile[profileId][pubId].feeProcessed) {
            revert FeeAlreadyProcessed();
        }
        _processCollectFee(profileId, pubId);
    }

    /**
     * @notice Returns the referrer profile in the given publication's auction.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param pubId The publication ID associated with the underlying publication.
     * @param bidder The address whose referrer profile should be returned.
     *
     * @return The ID of the referrer profile. Zero means no referral.
     */
    function getReferrerProfileIdOf(
        uint256 profileId,
        uint256 pubId,
        address bidder
    ) external view returns (uint256) {
        uint256 referrerProfileId = _referrerProfileIdByPubByProfile[profileId][
            pubId
        ][bidder];
        return referrerProfileId == profileId ? 0 : referrerProfileId;
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
        _verifyErc20Currency(initData.currency);
        _validateAndStoreRecipients(initData.recipients,profileId,pubId);

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
        //auction.recipients = initData.recipients;
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
        
        uint256 referrerProfileId = _referrerProfileIdByPubByProfile[profileId][
            pubId
        ][_auctionDataByPubByProfile[profileId][pubId].winner.profileOwner];
        
        RecipientData[] storage recipients = _recipientsByPubByProfile[profileId][pubId];

        if (referrerProfileId == profileId) {
            _processCollectFeeWithoutReferral(
                _auctionDataByPubByProfile[profileId][pubId].winningBid,
                _auctionDataByPubByProfile[profileId][pubId].currency,
                recipients
            );
        } else {
            _processCollectFeeWithReferral(
                _auctionDataByPubByProfile[profileId][pubId].winningBid,
                _auctionDataByPubByProfile[profileId][pubId].referralFee,
                referrerProfileId,
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

        uint256 len = recipients.length;

        uint256 i;
        while (i < len) {
            uint256 amountForRecipient = (adjustedAmount * recipients[i].split) / BPS_MAX;
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
     * @param referrerProfileId The token ID of the referrer's profile.
     * @param currency The currency in which the bids are denominated.
     * @param recipients The recipient of the auction's winner bid amount.
     */
    function _processCollectFeeWithReferral(
        uint256 winnerBid,
        uint16 referralFee,
        uint256 referrerProfileId,
        address currency,
        RecipientData[] memory recipients
    ) internal {
        (address treasury, uint16 treasuryFee) = _treasuryData();
        uint256 treasuryAmount = (winnerBid * treasuryFee) / BPS_MAX;
        uint256 adjustedAmount = winnerBid - treasuryAmount;
        if (referralFee > 0) {
            // The reason we levy the referral fee on the adjusted amount is so that referral fees
            // don't bypass the treasury fee, in essence referrals pay their fair share to the treasury.
            uint256 referralAmount = (adjustedAmount * referralFee) / BPS_MAX;
            adjustedAmount = adjustedAmount - referralAmount;

            IERC20(currency).safeTransfer(
                IERC721(HUB).ownerOf(referrerProfileId),
                referralAmount
            );
        }
        
        uint256 len = recipients.length;

        uint256 i;
        while (i < len) {
            uint256 amountForRecipient = (adjustedAmount * recipients[i].split) / BPS_MAX;
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
     * @notice Executes the given bid for the given auction. Each new successful bid transfers back the funds of the
     * previous winner and pulls funds from the new winning bidder.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param pubId The publication ID associated with the underlying publication.
     * @param referrerProfileId The token ID of the referrer's profile.
     * @param amount The bid amount to offer.
     * @param bidderOwner The owner's address of the bidder profile.
     * @param bidderProfileId The token ID of the bidder profile
     * @param bidderTransactionExecutor The address executing the bid
     */
    function _bid(
        uint256 profileId,
        uint256 pubId,
        uint256 referrerProfileId,
        uint256 amount,
        address bidderOwner,
        uint256 bidderProfileId,
        address bidderTransactionExecutor
    ) internal {
        AuctionData memory auction = _auctionDataByPubByProfile[profileId][
            pubId
        ];
        _validateBid(profileId, amount, bidderProfileId, auction);
        uint256 referrerProfileIdSet = _setReferrerProfileIdIfNotAlreadySet(
            profileId,
            pubId,
            referrerProfileId,
            bidderOwner
        );
        Winner memory newWinner = Winner({
            profileOwner: bidderOwner,
            profileId: bidderProfileId,
            transactionExecutor: bidderTransactionExecutor
        });
        uint256 endTimestamp = _setNewAuctionStorageStateAfterBid(
            profileId,
            pubId,
            amount,
            newWinner,
            auction
        );
        if (auction.winner.profileOwner != address(0)) {
            IERC20(auction.currency).safeTransfer(
                auction.winner.profileOwner,
                auction.winningBid
            );
        }
        IERC20(auction.currency).safeTransferFrom(
            bidderTransactionExecutor,
            address(this),
            amount
        );
        // `referrerProfileId` and `followNftTokenId` event params are tweaked to provide better semantics for indexers.
        emit BidPlaced(
            profileId,
            pubId,
            referrerProfileIdSet == profileId ? 0 : referrerProfileIdSet,
            amount,
            bidderOwner,
            bidderProfileId,
            bidderTransactionExecutor,
            endTimestamp,
            block.timestamp
        );
    }

    /**
     * @notice Valides if the given bid is valid for the given auction.
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
            FollowValidationLib.validateIsFollowingOrSelf(
                HUB,
                profileId,
                bidderProfileId
            );
        }
    }

    /**
     * @notice Updates the state of the auction data after a successful bid.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param pubId The publication ID associated with the underlying publication.
     * @param newWinningBid The amount of the new winning bid.
     * @param newWinner The new winning bidder.
     * @param prevAuctionState The state of the auction data before the bid, which will be overrided.
     *
     * @return A UNIX timestamp representing the `endTimestamp` of the new auction state.
     */
    function _setNewAuctionStorageStateAfterBid(
        uint256 profileId,
        uint256 pubId,
        uint256 newWinningBid,
        Winner memory newWinner,
        AuctionData memory prevAuctionState
    ) internal returns (uint256) {
        AuctionData storage nextAuctionState = _auctionDataByPubByProfile[
            profileId
        ][pubId];
        nextAuctionState.winner = newWinner;
        nextAuctionState.winningBid = newWinningBid;
        uint256 endTimestamp = prevAuctionState.endTimestamp;
        if (prevAuctionState.winner.profileOwner == address(0)) {
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
     * @param referrerProfileId The token ID of the referrer's profile.
     * @param bidder The address of the bidder whose referrer profile id is being set.
     *
     * @return The token ID of the referrer profile for the given bidder. Being equals to `profileId` means no referrer.
     */
    function _setReferrerProfileIdIfNotAlreadySet(
        uint256 profileId,
        uint256 pubId,
        uint256 referrerProfileId,
        address bidder
    ) internal returns (uint256) {
        uint256 referrerProfileIdSet = _referrerProfileIdByPubByProfile[
            profileId
        ][pubId][bidder];
        if (referrerProfileIdSet == 0) {
            _referrerProfileIdByPubByProfile[profileId][pubId][
                bidder
            ] = referrerProfileId;
            referrerProfileIdSet = referrerProfileId;
        }
        return referrerProfileIdSet;
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
        bool auctionStartsWithCurrentBid = auction.winner.profileOwner ==
            address(0);
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
        )internal{ 
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
            _recipientsByPubByProfile[profileId][pubId].push(recipients[i]);
            unchecked {
                ++i;
            }
        }

        if (totalSplits != BPS_MAX) {
            revert InvalidRecipientSplits();
        }
    }
}
