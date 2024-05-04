import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

import { module } from "@lens-protocol/metadata";
import { uploadMetadata } from "../lib/irys-service";
import { AuctionCollectAction } from "../typechain-types";
import { COLLECT_NFT, LENS_HUB, MODULE_REGISTRY } from "../config";

/**
 * Generates the metadata for the YourActionModule contract compliant with the Module Metadata Standard at:
 * https://docs.lens.xyz/docs/module-metadata-standard
 */
const metadata = module({
  name: "AuctionCollectAction",
  title: "Auction Collect Publication Action",
  description: "English auctions for 1 of 1 Lens Collects",
  authors: ["adonoso@itba.edu.ar", "paul@paulburke.co", "martijn.vanhalen@gmail.com"],
  initializeCalldataABI: JSON.stringify([
    { name: "availableSinceTimestamp", type: "uint64" },
    { name: "duration", type: "uint32" },
    { name: "minTimeAfterBid", type: "uint32" },
    { name: "reservePrice", type: "uint256" },
    { name: "minBidIncrement", type: "uint256" },
    { name: "referralFee", type: "uint16" },
    { name: "currency", type: "address" },
    {
      name: "recipients",
      type: "tuple(address,uint16)[]",
      components: [
        { name: "recipient", type: "address" },
        { name: "split", type: "uint16" },
      ],
    },
    { name: "onlyFollowers", type: "bool" },
    { name: "tokenName", type: "bytes32" },
    { name: "tokenSymbol", type: "bytes32" },
    { name: "tokenRoyalty", type: "uint16" },
  ]),
  processCalldataABI: JSON.stringify([{ name: "amount", type: "uint256" }]),
  attributes: [],
});

const deployAuctionCollectActionContract: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy, get } = hre.deployments;

  const lensHubAddress = LENS_HUB;

  let lensProtocol: string | undefined;
  try {
    const { address } = await get("MockLensProtocol");
    lensProtocol = address;
  } catch (e) {}

  if (!lensProtocol) {
    lensProtocol = LENS_HUB;
  }

  let lensGovernable: string | undefined;
  try {
    const { address } = await get("MockLensGovernable");
    lensGovernable = address;
  } catch (e) {}

  if (!lensGovernable) {
    lensGovernable = LENS_HUB;
  }

  let profileNFT: string | undefined;
  try {
    const { address } = await get("MockProfileNFT");
    profileNFT = address;
  } catch (e) {}

  if (!profileNFT) {
    profileNFT = LENS_HUB;
  }

  let moduleRegistry: string | undefined;
  try {
    const { address } = await get("ModuleRegistry");
    moduleRegistry = address;
  } catch (e) {}

  if (!moduleRegistry) {
    moduleRegistry = MODULE_REGISTRY;
  }

  let collectNFT: string | undefined;
  try {
    const { address } = await get("CustomCollectNFT");
    collectNFT = address;
  } catch (e) {}

  if (!collectNFT) {
    collectNFT = COLLECT_NFT;
  }

  await deploy("AuctionCollectAction", {
    from: deployer,
    args: [lensHubAddress, lensGovernable, profileNFT, lensProtocol, moduleRegistry, collectNFT],
    log: true,
    // autoMine: can be passed to the deploy function to make the deployment process faster on local networks by
    // automatically mining the contract deployment transaction. There is no effect on live networks.
    autoMine: true,
  });

  // Get the deployed contract
  const auctionActionModule = await hre.ethers.getContract<AuctionCollectAction>("AuctionCollectAction", deployer);

  // Upload the metadata to Arweave with Irys and set the URI on the contract
  const metadataURI = await uploadMetadata(metadata);
  await auctionActionModule.setModuleMetadataURI(metadataURI);

  // Add a delay before calling registerModule to allow for propagation
  await new Promise(resolve => setTimeout(resolve, 10000));

  // Register the module with the ModuleRegistry
  const registered = await auctionActionModule.registerModule();
  console.log("registered open action: tx=", registered.hash);

  const transfer = await auctionActionModule.transferOwnership("0xdaA5EBe0d75cD16558baE6145644EDdFcbA1e868");
  console.log("registered transferred ownership to 0xdaA5EBe0d75cD16558baE6145644EDdFcbA1e868", transfer.hash);
};

export default deployAuctionCollectActionContract;

// Tags are useful if you have multiple deploy files and only want to run one of them.
// e.g. yarn deploy --tags YourActionModule
deployAuctionCollectActionContract.tags = ["AuctionCollectAction"];
