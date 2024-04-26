import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

import { module } from "@lens-protocol/metadata";
import { uploadMetadata } from "../lib/irys-service";
import { AuctionActionModule } from "../typechain-types";
import { COLLECT_NFT, LENS_HUB, MODULE_REGISTRY } from "../config";

/**
 * Generates the metadata for the YourActionModule contract compliant with the Module Metadata Standard at:
 * https://docs.lens.xyz/docs/module-metadata-standard
 */
const metadata = module({
  name: "YourActionModule",
  title: "Your Open Action",
  description: "Description of your action",
  authors: ["some@email.com"],
  initializeCalldataABI: JSON.stringify([]),
  processCalldataABI: JSON.stringify([]),
  attributes: [],
});

/**
 * Deploys a contract named "YourActionModule" using the deployer account and
 * constructor arguments set to the deployer address
 *
 * @param hre HardhatRuntimeEnvironment object.
 */
const deployAuctionActionModuleContract: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy, get } = hre.deployments;

  const lensHubAddress = LENS_HUB;

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
    const { address } = await get("CollectNFT");
    collectNFT = address;
  } catch (e) {}

  if (!collectNFT) {
    collectNFT = COLLECT_NFT;
  }

  await deploy("AuctionActionModule", {
    from: deployer,
    args: [lensHubAddress, moduleRegistry, collectNFT],
    log: true,
    // autoMine: can be passed to the deploy function to make the deployment process faster on local networks by
    // automatically mining the contract deployment transaction. There is no effect on live networks.
    autoMine: true,
  });

  // Get the deployed contract
  const auctionActionModule = await hre.ethers.getContract<AuctionActionModule>("AuctionActionModule", deployer);

  // Upload the metadata to Arweave with Irys and set the URI on the contract
  const metadataURI = await uploadMetadata(metadata);
  await auctionActionModule.setModuleMetadataURI(metadataURI);

  // Add a delay before calling registerModule to allow for propagation
  await new Promise(resolve => setTimeout(resolve, 10000));

  // Register the module with the ModuleRegistry
  const registered = await auctionActionModule.registerModule();
  console.log("registered open action: tx=", registered.hash);
};

export default deployAuctionActionModuleContract;

// Tags are useful if you have multiple deploy files and only want to run one of them.
// e.g. yarn deploy --tags YourActionModule
deployAuctionActionModuleContract.tags = ["AuctionActionModule"];
