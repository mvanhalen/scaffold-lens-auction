import { expect } from "chai";
import { ethers } from "hardhat";
import {
  AuctionActionModule,
  CustomCollectNFT,
  MockLensGovernable,
  ModuleRegistry,
  TestToken,
} from "../typechain-types";
import getNextContractAddress from "../lib/get-next-contract-address";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { encodeBytes32String } from "ethers";

//Todo
// - referrals
// - ensure winner has NFT in wallet after claiming
// - follower-only bidding

describe("AuctionActionModule", () => {
  const PROFILE_ID = 1;
  const PUBLICATION_ID = 1;
  const FIRST_BIDDER_PROFILE_ID = 2;
  const SECOND_BIDDER_PROFILE_ID = 3;
  const BPS_MAX = 10000n;

  let auctionAction: AuctionActionModule;
  let testToken: TestToken;
  let moduleRegistry: ModuleRegistry;
  let collectNFT: CustomCollectNFT;
  let mockLensGovernable: MockLensGovernable;

  let lensHubAddress: string;
  let authorAddress: string;
  let firstBidderAddress: string;
  let secondBidderAddress: string;
  let tokenAddress: string;
  let treasuryFee: bigint;

  beforeEach(async () => {
    const [lensHub, author, firstBidder, secondBidder] = await ethers.getSigners();

    lensHubAddress = await lensHub.getAddress();
    authorAddress = await author.getAddress();
    firstBidderAddress = await firstBidder.getAddress();
    secondBidderAddress = await secondBidder.getAddress();

    const TestToken = await ethers.getContractFactory("TestToken");
    testToken = await TestToken.deploy();
    tokenAddress = await testToken.getAddress();

    await testToken.mint(firstBidderAddress, ethers.parseEther("10"));
    await testToken.mint(secondBidderAddress, ethers.parseEther("10"));

    const LensGovernable = await ethers.getContractFactory("MockLensGovernable");
    mockLensGovernable = await LensGovernable.deploy(lensHubAddress, 1000);
    treasuryFee = await mockLensGovernable.getTreasuryFee();

    // Deploy a new mock ModuleRegistry contract
    const ModuleRegistry = await ethers.getContractFactory("ModuleRegistry");
    moduleRegistry = await ModuleRegistry.deploy();

    await moduleRegistry.registerErc20Currency(await testToken.getAddress());

    const CollectNFT = await ethers.getContractFactory("CustomCollectNFT");
    collectNFT = await CollectNFT.deploy(lensHubAddress, getNextContractAddress(lensHubAddress));

    // Deploy a new TipActionModule contract for each test
    const AuctionActionModule = await ethers.getContractFactory("AuctionActionModule");
    auctionAction = await AuctionActionModule.deploy(
      lensHubAddress,
      await mockLensGovernable.getAddress(),
      await moduleRegistry.getAddress(),
      await collectNFT.getAddress(),
    );

    // Set token allowance on the action module
    const firstBidderTokenInstance = testToken.connect(firstBidder);
    const auctionAddress = await auctionAction.getAddress();
    await firstBidderTokenInstance.approve(auctionAddress, ethers.parseEther("10"));

    const secondBidderTokenInstance = testToken.connect(secondBidder);
    await secondBidderTokenInstance.approve(auctionAddress, ethers.parseEther("10"));
  });

  type InitializeParams = {
    availableSinceTimestamp?: number;
    duration?: number;
    minTimeAfterBid?: number;
    reservePrice?: bigint;
    minBidIncrement?: bigint;
    referralFee?: number;
    currency?: string;
    recipients?: [string, number][];
    onlyFollowers?: boolean;
    tokenName?: string;
    tokenSymbol?: string;
    tokenRoyalties?: number;
  };

  const initialize = async ({
    availableSinceTimestamp = 0,
    minTimeAfterBid = 30,
    duration = 60,
    reservePrice = 0n,
    minBidIncrement = ethers.parseEther("0.001"),
    referralFee = 1000,
    currency = tokenAddress,
    recipients = [[authorAddress, 10000]],
    onlyFollowers = false,
    tokenName = encodeBytes32String("Test NFT"),
    tokenSymbol = encodeBytes32String("TST-NFT"),
    tokenRoyalties = 1000,
  }: InitializeParams = {}) => {
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [
        "uint64",
        "uint32",
        "uint32",
        "uint256",
        "uint256",
        "uint16",
        "address",
        "tuple(address,uint16)[]",
        "bool",
        "bytes32",
        "bytes32",
        "uint16",
      ],
      [
        availableSinceTimestamp,
        duration,
        minTimeAfterBid,
        reservePrice,
        minBidIncrement,
        referralFee,
        currency,
        recipients,
        onlyFollowers,
        tokenName,
        tokenSymbol,
        tokenRoyalties,
      ],
    );
    const tx = await auctionAction.initializePublicationAction(PROFILE_ID, PUBLICATION_ID, authorAddress, data);
    return {
      tx,
      data,
      availableSinceTimestamp,
      duration,
      minTimeAfterBid,
      reservePrice,
      minBidIncrement,
      referralFee,
      currency,
      recipients,
      onlyFollowers,
      tokenName,
      tokenSymbol,
      tokenRoyalties,
    };
  };

  const getLatestBlockTimestamp = async () => {
    const latestBlock = await ethers.provider.getBlock("latest");
    return latestBlock?.timestamp ?? Math.floor(Date.now() / 1000);
  };

  it("Should initialize publication action", async () => {
    const {
      tx,
      data,
      availableSinceTimestamp,
      duration,
      minTimeAfterBid,
      reservePrice,
      minBidIncrement,
      referralFee,
      currency,
      onlyFollowers,
      tokenName,
      tokenSymbol,
      tokenRoyalties,
    } = await initialize();

    await expect(tx)
      .to.emit(auctionAction, "InitializedPublicationAction")
      .withArgs(PROFILE_ID, PUBLICATION_ID, authorAddress, data)
      .to.emit(auctionAction, "AuctionCreated")
      .withArgs(
        PROFILE_ID,
        PUBLICATION_ID,
        availableSinceTimestamp,
        duration,
        minTimeAfterBid,
        reservePrice,
        minBidIncrement,
        referralFee,
        currency,
        anyValue, // ethers only matches top-level values so we check recipients below
        onlyFollowers,
        tokenName,
        tokenSymbol,
        tokenRoyalties,
      );

    await expect(tx).not.to.revertedWithCustomError(auctionAction, "InitParamsInvalid");

    const auctionData = await auctionAction.getAuctionData(PROFILE_ID, PUBLICATION_ID);
    const recipientData = await auctionAction.getRecipients(PROFILE_ID, PUBLICATION_ID);

    // Test if the auction data is correctly set
    expect(auctionData.availableSinceTimestamp).to.equal(availableSinceTimestamp);
    expect(auctionData.duration).to.equal(duration);
    expect(auctionData.minTimeAfterBid).to.equal(minTimeAfterBid);
    expect(auctionData.reservePrice).to.equal(reservePrice);
    expect(auctionData.minBidIncrement).to.equal(minBidIncrement);
    expect(auctionData.referralFee).to.equal(referralFee);
    expect(auctionData.currency).to.equal(currency);
    expect(recipientData[0].recipient).to.equal(authorAddress);
    expect(auctionData.onlyFollowers).to.equal(onlyFollowers);
    expect(auctionData.tokenData.name).to.equal(tokenName);
    expect(auctionData.tokenData.symbol).to.equal(tokenSymbol);
    expect(auctionData.tokenData.royalty).to.equal(tokenRoyalties);
  });

  it("First bidder should be winner", async () => {
    await initialize();

    const amount = ethers.parseEther("0.001");
    const data = ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [amount, FIRST_BIDDER_PROFILE_ID]);

    const tx = auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: data,
    });

    await expect(tx)
      .to.emit(auctionAction, "ProcessedPublicationAction")
      .withArgs(PROFILE_ID, PUBLICATION_ID, firstBidderAddress, data)
      .to.emit(auctionAction, "BidPlaced")
      .withArgs(
        PROFILE_ID,
        PUBLICATION_ID,
        [],
        amount,
        firstBidderAddress,
        FIRST_BIDDER_PROFILE_ID,
        firstBidderAddress,
        anyValue,
        anyValue,
      );

    // Ensure the bidder is now the winner
    const auctionData = await auctionAction.getAuctionData(PROFILE_ID, PUBLICATION_ID);
    expect(auctionData.winner.profileOwner).to.equal(firstBidderAddress);
  });

  it("Valid higher bidder is winner", async () => {
    await initialize();

    const firstData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint256"],
      [ethers.parseEther("0.001"), FIRST_BIDDER_PROFILE_ID],
    );

    await auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: firstData,
    });

    const amount = ethers.parseEther("0.01");
    const secondData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint256"],
      [amount, SECOND_BIDDER_PROFILE_ID],
    );

    const secondTx = auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: SECOND_BIDDER_PROFILE_ID,
      actorProfileOwner: secondBidderAddress,
      transactionExecutor: secondBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: secondData,
    });

    await expect(secondTx)
      .to.emit(auctionAction, "BidPlaced")
      .withArgs(
        PROFILE_ID,
        PUBLICATION_ID,
        [],
        amount,
        secondBidderAddress,
        SECOND_BIDDER_PROFILE_ID,
        secondBidderAddress,
        anyValue,
        anyValue,
      );

    // Ensure the bidder is now the winner
    const auctionData = await auctionAction.getAuctionData(PROFILE_ID, PUBLICATION_ID);
    expect(auctionData.winner.profileOwner).to.equal(secondBidderAddress);
  });

  it("Bid less than current winner is insufficient", async () => {
    await initialize();

    const firstData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint256"],
      [ethers.parseEther("0.01"), FIRST_BIDDER_PROFILE_ID],
    );

    await auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: firstData,
    });

    const amount = ethers.parseEther("0.001");
    const secondData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint256"],
      [amount, SECOND_BIDDER_PROFILE_ID],
    );

    const secondTx = auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: SECOND_BIDDER_PROFILE_ID,
      actorProfileOwner: secondBidderAddress,
      transactionExecutor: secondBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: secondData,
    });

    await expect(secondTx).to.revertedWithCustomError(auctionAction, "InsufficientBidAmount");
  });

  it("Bid less than minimum increment is insufficient", async () => {
    await initialize();

    const firstData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint256"],
      [ethers.parseEther("0.001"), FIRST_BIDDER_PROFILE_ID],
    );

    await auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: firstData,
    });

    const amount = ethers.parseEther("0.0015");
    const secondData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint256"],
      [amount, SECOND_BIDDER_PROFILE_ID],
    );

    const secondTx = auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: SECOND_BIDDER_PROFILE_ID,
      actorProfileOwner: secondBidderAddress,
      transactionExecutor: secondBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: secondData,
    });

    await expect(secondTx).to.revertedWithCustomError(auctionAction, "InsufficientBidAmount");
  });

  it("Winner can claim after auction ends", async () => {
    await initialize();

    const amount = ethers.parseEther("0.001");
    const data = ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [amount, FIRST_BIDDER_PROFILE_ID]);

    await auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: data,
    });

    // Increase time to end the auction
    await ethers.provider.send("evm_increaseTime", [60]);
    await ethers.provider.send("evm_mine", []);

    const claimTx = auctionAction.claim(PROFILE_ID, PUBLICATION_ID);
    await expect(claimTx)
      .to.emit(auctionAction, "Collected")
      .withArgs(PROFILE_ID, PUBLICATION_ID, FIRST_BIDDER_PROFILE_ID, firstBidderAddress, anyValue, 1, anyValue);

    const auctionData = await auctionAction.getAuctionData(PROFILE_ID, PUBLICATION_ID);
    expect(auctionData.collected).to.equal(true);
    expect(auctionData.feeProcessed).to.equal(true);
    expect(auctionData.winningBid).to.equal(amount);
    expect(auctionData.endTimestamp).not.to.equal(0);
  });

  it("Winner cannot claim before auction ends", async () => {
    await initialize();

    const amount = ethers.parseEther("0.001");
    const data = ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [amount, FIRST_BIDDER_PROFILE_ID]);
    const firstBidTx = auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: data,
    });

    await expect(firstBidTx).emit(auctionAction, "BidPlaced");

    const claimTx = auctionAction.claim(PROFILE_ID, PUBLICATION_ID);
    await expect(claimTx).to.revertedWithCustomError(auctionAction, "OngoingAuction");

    const amountSecond = ethers.parseEther("0.002");
    const dataSecond = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint256"],
      [amountSecond, SECOND_BIDDER_PROFILE_ID],
    );
    const secondBidTx = auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: SECOND_BIDDER_PROFILE_ID,
      actorProfileOwner: secondBidderAddress,
      transactionExecutor: secondBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: dataSecond,
    });

    await expect(secondBidTx).emit(auctionAction, "BidPlaced");

    const claimTxSecond = auctionAction.claim(PROFILE_ID, PUBLICATION_ID);
    await expect(claimTxSecond).to.revertedWithCustomError(auctionAction, "OngoingAuction");

    // Increase time to go to end auction
    await ethers.provider.send("evm_increaseTime", [61]);
    await ethers.provider.send("evm_mine", []);

    // Ensure the bidder is now the winner
    const auctionData = await auctionAction.getAuctionData(PROFILE_ID, PUBLICATION_ID);
    expect(auctionData.winner.profileOwner).to.equal(secondBidderAddress);

    const claimTxDone = auctionAction.claim(PROFILE_ID, PUBLICATION_ID);
    await expect(claimTxDone)
      .to.emit(auctionAction, "Collected")
      .withArgs(PROFILE_ID, PUBLICATION_ID, SECOND_BIDDER_PROFILE_ID, secondBidderAddress, anyValue, 1, anyValue);
  });

  it("Bid cannot be placed before auction start time", async () => {
    const latestTimestamp = await getLatestBlockTimestamp();

    //set time now + 120 seconds
    const availableSinceTimestamp = latestTimestamp + 120;

    await initialize({
      availableSinceTimestamp,
      minTimeAfterBid: 30,
      duration: 300,
    });

    const amount = ethers.parseEther("0.001");
    const data = ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [amount, FIRST_BIDDER_PROFILE_ID]);
    const toEarlyBidTx = auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: data,
    });

    await expect(toEarlyBidTx).to.revertedWithCustomError(auctionAction, "UnavailableAuction");
  });

  it("Bid can be placed after auction start time", async () => {
    const latestTimestamp = await getLatestBlockTimestamp();

    //set time now + 120 seconds
    const availableSinceTimestamp = latestTimestamp + 120;

    await initialize({
      availableSinceTimestamp,
      minTimeAfterBid: 30,
      duration: 300,
    });

    const amount = ethers.parseEther("0.001");
    const data = ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [amount, FIRST_BIDDER_PROFILE_ID]);

    // // Increase time to go to start of auction
    await ethers.provider.send("evm_setNextBlockTimestamp", [availableSinceTimestamp + 121]);
    await ethers.provider.send("evm_mine", []);

    //expect to work...
    const onTimeBid = auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: data,
    });
    await expect(onTimeBid).to.emit(auctionAction, "BidPlaced");
  });

  it("Auction is extended by minTimeAfterBid after last minute bids", async () => {
    const minTimeAfterBid = 30;

    await initialize({
      minTimeAfterBid,
      duration: 120,
    });

    // Place the first bid to start the auction
    const firstAmount = ethers.parseEther("0.001");
    const firstData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint256"],
      [firstAmount, FIRST_BIDDER_PROFILE_ID],
    );
    const firstBid = await auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: firstData,
    });

    const firstBidBlock = await firstBid.getBlock();
    if (!firstBidBlock) {
      throw new Error("Block not found");
    }

    // Increase time to get near end of auction
    await ethers.provider.send("evm_setNextBlockTimestamp", [firstBidBlock.timestamp + 119]);
    await ethers.provider.send("evm_mine", []);

    const secondAmount = ethers.parseEther("0.01");
    const secondData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint256"],
      [secondAmount, FIRST_BIDDER_PROFILE_ID],
    );
    const secondBid = await auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: secondData,
    });
    const secondBidBlock = await secondBid.getBlock();
    if (!secondBidBlock) {
      throw new Error("Block not found");
    }

    const auctionData = await auctionAction.getAuctionData(PROFILE_ID, PUBLICATION_ID);
    expect(auctionData.endTimestamp).to.equal(secondBidBlock.timestamp + minTimeAfterBid);
  });

  it("Reserve price is met", async () => {
    await initialize({
      reservePrice: ethers.parseEther("1"),
    });

    const amount = ethers.parseEther("1");
    const data = ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [amount, FIRST_BIDDER_PROFILE_ID]);

    const tx = auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: data,
    });

    await expect(tx)
      .to.emit(auctionAction, "BidPlaced")
      .withArgs(
        PROFILE_ID,
        PUBLICATION_ID,
        [],
        amount,
        firstBidderAddress,
        FIRST_BIDDER_PROFILE_ID,
        firstBidderAddress,
        anyValue,
        anyValue,
      );

    // Ensure the bidder is now the winner
    const auctionData = await auctionAction.getAuctionData(PROFILE_ID, PUBLICATION_ID);
    expect(auctionData.winner.profileOwner).to.equal(firstBidderAddress);
  });

  it("Reserve price is not met", async () => {
    await initialize({
      reservePrice: ethers.parseEther("1"),
    });

    const amount = ethers.parseEther("0.5");
    const data = ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [amount, FIRST_BIDDER_PROFILE_ID]);

    const tx = auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: data,
    });

    await expect(tx).to.revertedWithCustomError(auctionAction, "InsufficientBidAmount");
  });

  // test referrals
  it("Referral fee is paid to referrer", async () => {
    const referrerStartingBalance = await testToken.balanceOf(secondBidderAddress);

    await initialize({
      referralFee: 1000, // 10%
    });

    const amount = ethers.parseEther("1");
    const data = ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [amount, FIRST_BIDDER_PROFILE_ID]);

    await auctionAction.processPublicationAction({
      publicationActedProfileId: PROFILE_ID,
      publicationActedId: PUBLICATION_ID,
      actorProfileId: FIRST_BIDDER_PROFILE_ID,
      actorProfileOwner: firstBidderAddress,
      transactionExecutor: firstBidderAddress,
      referrerProfileIds: [SECOND_BIDDER_PROFILE_ID],
      referrerPubIds: [],
      referrerPubTypes: [],
      actionModuleData: data,
    });

    // Ensure the referrer has received the fee
    const referrerBalance = await testToken.balanceOf(secondBidderAddress);
    const adjustedAmount = amount - amount * (treasuryFee / BPS_MAX);
    expect(referrerBalance).to.equal(referrerStartingBalance + adjustedAmount / 10n);
  });
});
