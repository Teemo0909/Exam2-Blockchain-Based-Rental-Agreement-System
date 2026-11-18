require("@nomicfoundation/hardhat-toolbox");
const { vars } = require("hardhat/config");

// Key lives in hardhat's var store (outside the repo): npx hardhat vars set SEPOLIA_PRIVATE_KEY
const networks = vars.has("SEPOLIA_PRIVATE_KEY")
  ? { sepolia: { url: vars.get("SEPOLIA_RPC_URL", "https://ethereum-sepolia-rpc.publicnode.com"), accounts: [vars.get("SEPOLIA_PRIVATE_KEY")] } }
  : {};

module.exports = { solidity: "0.8.24", networks };
