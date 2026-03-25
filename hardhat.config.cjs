require("dotenv").config({ quiet: true });
require("@nomicfoundation/hardhat-toolbox");

const deployerAccounts = process.env.DEPLOYER_PRIVATE_KEY
  ? [process.env.DEPLOYER_PRIVATE_KEY]
  : undefined;

function buildNetworkConfig(url) {
  if (!url) {
    return undefined;
  }

  return deployerAccounts ? { url, accounts: deployerAccounts } : { url };
}

const networks = {
  hardhat: {},
  localhost: buildNetworkConfig(process.env.LOCALHOST_RPC_URL || "http://127.0.0.1:8545"),
};

const bscTestnet = buildNetworkConfig(process.env.BSC_TESTNET_RPC_URL);
if (bscTestnet) {
  networks.bscTestnet = bscTestnet;
}

const bsc = buildNetworkConfig(process.env.BSC_MAINNET_RPC_URL);
if (bsc) {
  networks.bsc = bsc;
}

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache-hardhat",
    artifacts: "./artifacts-hardhat",
  },
  networks,
};
