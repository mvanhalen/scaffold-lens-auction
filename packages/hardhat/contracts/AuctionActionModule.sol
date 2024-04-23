// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.23;

import {IModuleRegistry} from "lens-modules/contracts/interfaces/IModuleRegistry.sol";
import {Types} from 'lens-modules/contracts/libraries/constants/Types.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol';
import {Errors} from 'lens-modules/contracts/libraries/constants/Errors.sol';
//import {FeeModuleBase} from 'lens-modules/contracts/modules/FeeModuleBase.sol';
import {IPublicationActionModule} from "lens-modules/contracts/interfaces/IPublicationActionModule.sol";
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IERC721Timestamped} from 'lens-modules/contracts/interfaces/IERC721Timestamped.sol';
import {ILensHub} from 'lens-modules/contracts/interfaces/ILensHub.sol';
import {LensModule} from 'lens-modules/contracts/modules/LensModule.sol';
import {LensModuleMetadata} from 'lens-modules/contracts/modules/LensModuleMetadata.sol';
import {LensModuleRegistrant} from "lens-modules/contracts/modules/base/LensModuleRegistrant.sol";
import {HubRestricted} from "lens-modules/contracts/base/HubRestricted.sol";
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ModuleTypes} from "lens-modules/contracts/modules/libraries/constants/ModuleTypes.sol";
import {FollowValidationLib} from "lens-modules/contracts/modules/libraries/FollowValidationLib.sol";


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
    address recipient;
    address winner;
    bool onlyFollowers;
    bool collected;
    bool feeProcessed;
}

error ModuleDataMismatch();

/**
 * @title AuctionCollectActionModule
 * @author Lens Protocol, Martijn van Halen and Paul Burke
 *
 * @notice This module works by creating an English auction for the underlying publication. After the auction ends, only
 * the auction winner is allowed to collect the publication.
 */
contract AuctionCollectModule is
    EIP712,
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
        address recipient,
        bool onlyFollowers
    );
    event BidPlaced(
        uint256 indexed profileId,
        uint256 indexed pubId,
        uint256 referrerProfileId,
        uint256 amount,
        address bidder,
        uint256 bidderProfileId,
        uint256 endTimestamp,
        uint256 timestamp
    );
    event FeeProcessed(
        uint256 indexed profileId,
        uint256 indexed pubId,
        uint256 timestamp
    );

    mapping(address => uint256) public nonces;

    mapping(uint256 => mapping(uint256 => AuctionData))
        internal _auctionDataByPubByProfile;

    /**
     * @dev Maps a given bidder's address to its referrer profile ID. Referrer matching publication's profile ID means
     * no referral, referrer being zero means that bidder has not bidded yet on this auction.
     * The referrer is set through, and only through, the first bidder's bid on each auction.
     */
    mapping(uint256 => mapping(uint256 => mapping(address => uint256)))
        internal _referrerProfileIdByPubByProfile;

    constructor(
        address hub,
        IModuleRegistry moduleRegistry
    )
        Ownable()
        HubRestricted(hub)
        LensModuleMetadata()
        LensModuleRegistrant(moduleRegistry)
        EIP712("AuctionCollectModule", "1")
    {}

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
        (
            uint64 availableSinceTimestamp,
            uint32 duration,
            uint32 minTimeAfterBid,
            uint256 reservePrice,
            uint256 minBidIncrement,
            uint16 referralFee,
            address currency,
            address recipient,
            bool onlyFollowers
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
                    address,
                    bool
                )
            );
        if (
            duration == 0 ||
            duration < minTimeAfterBid ||
            !MODULE_REGISTRY.isErc20CurrencyRegistered(currency) ||
            referralFee > BPS_MAX
        ) {
            revert Errors.InitParamsInvalid();
        }
        _initAuction(
            profileId,
            pubId,
            availableSinceTimestamp,
            duration,
            minTimeAfterBid,
            reservePrice,
            minBidIncrement,
            referralFee,
            currency,
            recipient,
            onlyFollowers
        );
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

        (uint256 rootProfileId, uint256 rootPubId) = _getRootPublication(
            params.publicationActedProfileId,
            params.publicationActedId
        );
        
        (
            uint256 amount,
            uint256 bidderProfileId
        ) = abi.decode(
                params.actionModuleData,
                (
                    uint256,
                    uint256
                )
            );
        
        _bid(
            rootProfileId,
            rootPubId,
            params.publicationActedProfileId,
            amount,
            params.transactionExecutor,
            bidderProfileId
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

    /**
     * @notice Processes a collect action for the given publication, this can only be called by the hub.
     *
     * @dev Process the collect by ensuring:
     *  1. Underlying publication's auction has finished.
     *  2. Parameters passed matches expected values (collector is the winner, correct referral info & no custom data).
     *  3. Publication has not been collected yet.
     * This function will also process collect fees if they have not been already processed through `processCollectFee`.
     *
     *
     */
    function processCollect(
        uint256 referrerProfileId,
        address collector,
        uint256 profileId,
        uint256 pubId,
        ModuleTypes.ProcessCollectParams calldata processCollectParams
        //ModuleTypes.ProcessCollectParams calldata data
    ) external onlyHub returns (bytes memory)   {
        //checks basic collect settings, like follower only and end date
        //_validateAndStoreCollect(processCollectParams);

        // Override processCollect to add custom logic for processing the collect
        if (processCollectParams.referrerProfileIds.length == 0) {
           //_processCollect(processCollectParams);
        } else {
           //_processCollectWithReferral(processCollectParams);
        }
    
        if (
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
        if (
            collector != _auctionDataByPubByProfile[profileId][pubId].winner ||
            referrerProfileId !=
            _referrerProfileIdByPubByProfile[profileId][pubId][collector]
        ) {
            revert ModuleDataMismatch();
        }
        if (_auctionDataByPubByProfile[profileId][pubId].collected) {
            revert CollectAlreadyProcessed();
        }

        _auctionDataByPubByProfile[profileId][pubId].collected = true;
        if (!_auctionDataByPubByProfile[profileId][pubId].feeProcessed) {
            _processCollectFee(profileId, pubId);
        }
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
     * @notice Using EIP-712 signatures, places a bid by the given amount on the given publication's auction.
     * If the publication is a mirror, the pointed publication auction will be used, setting the mirror's profileId
     * as referrer if it's the first bid in the auction.
     * Transaction will fail if the bid offered is below auction's current best price.
     *
     * @dev It will pull the tokens from the bidder to ensure the collect fees can be processed if the bidder ends up
     * being the winner after auction ended. If a better bid is placed in the future by a different bidder, funds will
     * be automatically transferred to the previous winner.
     *
     * @param profileId The token ID of the profile associated with the publication, could be a mirror.
     * @param pubId The publication ID associated with the publication, could be a mirror.
     * @param amount The bid amount to offer.
     * @param bidder The address of the bidder.
     * @param bidderProfileId The ProfileId of the bidder.
     * @param sig The EIP-712 signature for this operation.
     */
    function bidWithSig(
        uint256 profileId,
        uint256 pubId,
        uint256 amount,
        address bidder,
        uint256 bidderProfileId,
        Types.EIP712Signature calldata sig
    ) external {
        _validateBidSignature(
            profileId,
            pubId,
            amount,
            bidder,
            bidderProfileId,
            sig
        );
        (uint256 rootProfileId, uint256 rootPubId) = _getRootPublication(
            profileId,
            pubId
        );
        _bid(
            rootProfileId,
            rootPubId,
            profileId,
            amount,
            bidder,
            bidderProfileId
        );
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
     * @param availableSinceTimestamp The UNIX timestamp after bids can start to be placed.
     * @param duration The seconds that the auction will last after the first bid has been placed.
     * @param minTimeAfterBid The minimum time, in seconds, that must always remain between last bid's timestamp
     * and `endTimestamp`. This restriction could make `endTimestamp` to be re-computed and updated.
     * @param reservePrice The minimum bid price accepted.
     * @param minBidIncrement The minimum amount by which a new bid must overcome the last bid.
     * @param referralFee The percentage of the fee that will be transferred to the referrer in case of having one.
     * Measured in basis points, each basis point represents 0.01%.
     * @param currency The currency in which the bids are denominated.
     * @param recipient The recipient of the auction's winner bid amount.
     * @param onlyFollowers Indicates whether followers are the only allowed to bid, and collect, or not.
     */
    function _initAuction(
        uint256 profileId,
        uint256 pubId,
        uint64 availableSinceTimestamp,
        uint32 duration,
        uint32 minTimeAfterBid,
        uint256 reservePrice,
        uint256 minBidIncrement,
        uint16 referralFee,
        address currency,
        address recipient,
        bool onlyFollowers
    ) internal {
        AuctionData storage auction = _auctionDataByPubByProfile[profileId][
            pubId
        ];
        auction.availableSinceTimestamp = availableSinceTimestamp;
        auction.duration = duration;
        auction.minTimeAfterBid = minTimeAfterBid;
        auction.reservePrice = reservePrice;
        auction.minBidIncrement = minBidIncrement;
        auction.referralFee = referralFee;
        auction.currency = currency;
        auction.recipient = recipient;
        auction.onlyFollowers = onlyFollowers;
        emit AuctionCreated(
            profileId,
            pubId,
            availableSinceTimestamp,
            duration,
            minTimeAfterBid,
            reservePrice,
            minBidIncrement,
            referralFee,
            currency,
            recipient,
            onlyFollowers
        );
    }
    // Declare the _treasuryData function and its return types
    function _treasuryData() internal view returns (address, uint16) {
        ILensHub HUB;
        // Add your implementation here
        return HUB.getTreasuryData();
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
        ][_auctionDataByPubByProfile[profileId][pubId].winner];
        if (referrerProfileId == profileId) {
            _processCollectFeeWithoutReferral(
                _auctionDataByPubByProfile[profileId][pubId].winningBid,
                _auctionDataByPubByProfile[profileId][pubId].currency,
                _auctionDataByPubByProfile[profileId][pubId].recipient
            );
        } else {
            _processCollectFeeWithReferral(
                _auctionDataByPubByProfile[profileId][pubId].winningBid,
                _auctionDataByPubByProfile[profileId][pubId].referralFee,
                referrerProfileId,
                _auctionDataByPubByProfile[profileId][pubId].currency,
                _auctionDataByPubByProfile[profileId][pubId].recipient
            );
        }
        emit FeeProcessed(profileId, pubId, block.timestamp);
    }
       
    /**
     * @notice Process the fees sending the winner amount to the recipient.
     *
     * @param winnerBid The amount of the winner bid.
     * @param currency The currency in which the bids are denominated.
     * @param recipient The recipient of the auction's winner bid amount.
     */
    function _processCollectFeeWithoutReferral(
        uint256 winnerBid,
        address currency,
        address recipient
    ) internal {
        (address treasury, uint16 treasuryFee) = _treasuryData();

       
        uint256 treasuryAmount = (winnerBid * treasuryFee) / BPS_MAX;
        uint256 adjustedAmount = winnerBid - treasuryAmount;
        IERC20(currency).safeTransfer(recipient, adjustedAmount);
        if (treasuryAmount > 0) {
            IERC20(currency).safeTransfer(treasury, treasuryAmount);
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
     * @param recipient The recipient of the auction's winner bid amount.
     */
    function _processCollectFeeWithReferral(
        uint256 winnerBid,
        uint16 referralFee,
        uint256 referrerProfileId,
        address currency,
        address recipient
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
        IERC20(currency).safeTransfer(recipient, adjustedAmount);
        if (treasuryAmount > 0) {
            IERC20(currency).safeTransfer(treasury, treasuryAmount);
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
     * @param bidder The address of the bidder.
     * @param bidderProfileId The token ID of the bidder profile
     */
    function _bid(
        uint256 profileId,
        uint256 pubId,
        uint256 referrerProfileId,
        uint256 amount,
        address bidder,
        uint256 bidderProfileId
    ) internal {
        AuctionData memory auction = _auctionDataByPubByProfile[profileId][
            pubId
        ];
        _validateBid(profileId, amount, bidder,bidderProfileId, auction);
        uint256 referrerProfileIdSet = _setReferrerProfileIdIfNotAlreadySet(
            profileId,
            pubId,
            referrerProfileId,
            bidder
        );
        uint256 endTimestamp = _setNewAuctionStorageStateAfterBid(
            profileId,
            pubId,
            amount,
            bidder,
            auction
        );
        if (auction.winner != address(0)) {
            IERC20(auction.currency).safeTransfer(
                auction.winner,
                auction.winningBid
            );
        }
        IERC20(auction.currency).safeTransferFrom(
            bidder,
            address(this),
            amount
        );
        // `referrerProfileId` and `followNftTokenId` event params are tweaked to provide better semantics for indexers.
        emit BidPlaced(
            profileId,
            pubId,
            referrerProfileIdSet == profileId ? 0 : referrerProfileIdSet,
            amount,
            bidder,
            bidderProfileId,
            endTimestamp,
            block.timestamp
        );
    }

    /**
     * @notice Valides if the given bid is valid for the given auction.
     *
     * @param profileId The token ID of the profile associated with the underlying publication.
     * @param amount The bid amount to offer.
     * @param bidder The address of the bidder.
     * @param bidderProfileId The token ID of the bidder profile.
     * @param auction The data of the auction where the bid is being placed.
     */
    function _validateBid(
        uint256 profileId,
        uint256 amount,
        address bidder,
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
        //disabled for now
        if (auction.onlyFollowers) {
            _validateFollow(
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
        address newWinner,
        AuctionData memory prevAuctionState
    ) internal returns (uint256) {
        AuctionData storage nextAuctionState = _auctionDataByPubByProfile[
            profileId
        ][pubId];
        nextAuctionState.winner = newWinner;
        nextAuctionState.winningBid = newWinningBid;
        uint256 endTimestamp = prevAuctionState.endTimestamp;
        if (prevAuctionState.winner == address(0)) {
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
        bool auctionStartsWithCurrentBid = auction.winner == address(0);
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

    /**
     * @notice Checks the given Follow NFT is owned by the given follower, is part of the given followed profile's
     * follow NFT collection and was minted before the given deadline.
     *
     * @param profileId The token ID of the profile associated with the publication.
     * @param followerId The profileId performing the follow operation.
     * valid for this scenario.
     */
    function _validateFollow(
        uint256 profileId,
        uint256 followerId
    ) internal view {
        
        FollowValidationLib.validateIsFollowingOrSelf(
            HUB,
            followerId,
            profileId
        );
        //address followNFT = ILensHub(HUB).getFollowNFT(profileId);
        //if (
            //ILensHub(HUB).isFollowing(profileId, follower)
            // followNFT == address(0) ||
            // IERC721(followNFT).ownerOf(followNftTokenId) != follower ||
            // IERC721Timestamped(followNFT).mintTimestampOf(followNftTokenId) >
            // maxValidFollowTimestamp
        // ) {
        //     revert Errors.FollowInvalid();
        // }
    }

    /**
     * @notice Returns the pointed publication if the passed one is a mirror, otherwise just returns the passed one.
     *
     * @param profileId The token ID of the profile associated with the publication, could be a mirror.
     * @param pubId The publication ID associated with the publication, could be a mirror.
     */
    function _getRootPublication(
        uint256 profileId,
        uint256 pubId
    ) internal view returns (uint256, uint256) {
        Types.PublicationMemory memory publication = ILensHub(HUB).getPublication(
            profileId,
            pubId
        );
        if (publication.referenceModule != address(0)) {
            return (publication.rootProfileId, publication.rootPubId);
        } else {
            if (publication.pointedProfileId == 0) {
                revert Errors.PublicationDoesNotExist();
            }
            return (publication.pointedProfileId, publication.pointedPubId);
        }
    }

    /**
     * @notice Checks if the signature for the `bidWithSig` function is valid according EIP-712 standard.
     *
     * @param profileId The token ID of the profile associated with the publication, could be a mirror.
     * @param pubId The publication ID associated with the publication, could be a mirror.
     * @param amount The bid amount to offer.
     * @param bidder The address of the bidder.
     * @param bidderProfileId The token ID of the bidder profile
     * @param sig The EIP-712 signature to validate.
     */
    function _validateBidSignature(
        uint256 profileId,
        uint256 pubId,
        uint256 amount,
        address bidder,
        uint256 bidderProfileId,
        Types.EIP712Signature calldata sig
    ) internal {
        unchecked {
            _validateRecoveredAddress(
                _calculateDigest(
                    abi.encode(
                        keccak256(
                            "BidWithSig(uint256 profileId,uint256 pubId,uint256 amount,uint256 nonce,uint256 bidderProfileId,uint256 deadline)"
                        ),
                        profileId,
                        pubId,
                        amount,
                        nonces[bidder]++,
                        bidderProfileId,
                        sig.deadline
                    )
                ),
                bidder,
                sig
            );
        }
    }

    /**
     * @notice Checks the recovered address is the expected signer for the given signature.
     *
     * @param digest The expected signed data.
     * @param expectedAddress The address of the expected signer.
     * @param sig The signature.
     */
    function _validateRecoveredAddress(
        bytes32 digest,
        address expectedAddress,
        Types.EIP712Signature calldata sig
    ) internal view {
        if (sig.deadline < block.timestamp) {
            revert Errors.SignatureExpired();
        }
        address recoveredAddress = ecrecover(digest, sig.v, sig.r, sig.s);
        if (
            recoveredAddress == address(0) ||
            recoveredAddress != expectedAddress
        ) {
            revert Errors.SignatureInvalid();
        }
    }

    /**
     * @notice Calculates the digest for the given bytes according EIP-712 standard.
     *
     * @param message The message, as bytes, to calculate the digest from.
     */
    function _calculateDigest(
        bytes memory message
    ) internal view returns (bytes32) {
        return keccak256(
                            abi.encodePacked(
                    "\x19\x01",
                    EIP712._domainSeparatorV4(),
                    keccak256(message)
                )
            );
    }
} 