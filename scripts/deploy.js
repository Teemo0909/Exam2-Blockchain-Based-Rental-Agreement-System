const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

async function main() {
  const c = await hre.ethers.deployContract("RentalAgreement");
  await c.waitForDeployment();
  const { abi } = await hre.artifacts.readArtifact("RentalAgreement");
  const { chainId } = await hre.ethers.provider.getNetwork();
  const { blockNumber: deployBlock } = await c.deploymentTransaction().wait();
  const out = { address: await c.getAddress(), chainId: Number(chainId), deployBlock, abi };
  fs.writeFileSync(path.join(__dirname, "../docs/contract.json"), JSON.stringify(out, null, 2));
  console.log(`RentalAgreement deployed to ${out.address} (chain ${out.chainId})`);
}

main().catch((e) => { console.error(e); process.exit(1); });
