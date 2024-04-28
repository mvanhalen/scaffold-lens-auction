import { expect } from "chai";
import { ethers } from "hardhat";
import { AuctionActionModule, CustomCollectNFT, ModuleRegistry, TestToken } from "../typechain-types";
import getNextContractAddress from "../lib/get-next-contract-address";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";

describe("AuctionActionModule", () => {
  const PROFILE_ID = 1;
  const PUBLICATION_ID = 1;
  const FIRST_BIDDER_PROFILE_ID = 2;
  const SECOND_BIDDER_PROFILE_ID = 3;

  let auctionAction: AuctionActionModule;
  let testToken: TestToken;
  let moduleRegistry: ModuleRegistry;
  let collectNFT: CustomCollectNFT;

  let lensHubAddress: string;
  let authorAddress: string;
  let firstBidderAddress: string;
  let secondBidderAddress: string;

  beforeEach(async () => {
    // Get the ContractFactory and Signers here.
    const [lensHub, author, firstBidder, secondBidder] = await ethers.getSigners();

    lensHubAddress = await lensHub.getAddress();
    authorAddress = await author.getAddress();
    firstBidderAddress = await firstBidder.getAddress();
    secondBidderAddress = await secondBidder.getAddress();

    const TestToken = await ethers.getContractFactory("TestToken");
    testToken = await TestToken.deploy();

    await testToken.mint(firstBidderAddress, ethers.parseEther("10"));
    await testToken.mint(secondBidderAddress, ethers.parseEther("10"));

    // Deploy a new mock ModuleRegistry contract
    const ModuleRegistry = await ethers.getContractFactory("ModuleRegistry");
    moduleRegistry = await ModuleRegistry.deploy();

    await moduleRegistry.registerErc20Currency(await testToken.getAddress());

    const CollectNFT = await ethers.getContractFactory("CustomCollectNFT");
    collectNFT = await CollectNFT.deploy(
      lensHubAddress,
      getNextContractAddress(lensHubAddress),
      "TEST",
      "Custom NFT Title",
      1000,
    );

    // Deploy a new TipActionModule contract for each test
    const AuctionActionModule = await ethers.getContractFactory("AuctionActionModule");
    auctionAction = await AuctionActionModule.deploy(
      lensHubAddress,
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

  const initialize = async () => {
    const currency = await testToken.getAddress();
    const availableSinceTimestamp = 0;
    const duration = 60;
    const minTimeAfterBid = 30;
    const reservePrice = 0;
    const minBidIncrement = ethers.parseEther("0.001");
    const referralFee = 1000;
    const onlyFollowers = false;
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint64", "uint32", "uint32", "uint256", "uint256", "uint16", "address", "address", "bool"],
      [
        availableSinceTimestamp,
        duration,
        minTimeAfterBid,
        reservePrice,
        minBidIncrement,
        referralFee,
        currency,
        authorAddress,
        onlyFollowers,
      ],
    );
    const tx = auctionAction.initializePublicationAction(PROFILE_ID, PUBLICATION_ID, authorAddress, data);
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
      authorAddress,
      onlyFollowers,
    };
  };

  // Test case for initializePublicationAction function
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
      authorAddress,
      onlyFollowers,
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
        authorAddress,
        onlyFollowers,
      );

    await expect(tx).not.to.revertedWithCustomError(auctionAction, "InitParamsInvalid");

    // Get the tip receiver
    const auctionData = await auctionAction.getAuctionData(PROFILE_ID, PUBLICATION_ID);

    // Test if the auction data is correctly set
    expect(auctionData.availableSinceTimestamp).to.equal(availableSinceTimestamp);
    expect(auctionData.duration).to.equal(duration);
    expect(auctionData.minTimeAfterBid).to.equal(minTimeAfterBid);
    expect(auctionData.reservePrice).to.equal(reservePrice);
    expect(auctionData.minBidIncrement).to.equal(minBidIncrement);
    expect(auctionData.referralFee).to.equal(referralFee);
    expect(auctionData.currency).to.equal(currency);
    expect(auctionData.recipient).to.equal(authorAddress);
    expect(auctionData.onlyFollowers).to.equal(onlyFollowers);
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
        0,
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
        0,
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
});
