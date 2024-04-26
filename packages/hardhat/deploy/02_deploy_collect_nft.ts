import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { ethers } from "hardhat";
import { LENS_HUB } from "../config";

async function getNextContractAddress(senderAddress: string): Promise<string> {
  const nonce = await ethers.provider.getTransactionCount(senderAddress);
  const contractAddress = ethers.getCreateAddress({
    from: senderAddress,
    nonce: nonce + 1, // Use the next nonce to predict the next contract address
  });
  return contractAddress;
}

const deployCollectNFT: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  const lensHubAddress = LENS_HUB;

  // Predict the Action address because of circular dependency
  const collectPublicationActionAddress = await getNextContractAddress(deployer);

  await deploy("CollectNFT", {
    from: deployer,
    args: [lensHubAddress, collectPublicationActionAddress],
    log: true,
    autoMine: true,
  });
};

export default deployCollectNFT;

deployCollectNFT.tags = ["CollectNFT"];
