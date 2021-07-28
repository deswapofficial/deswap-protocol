require("@nomiclabs/hardhat-waffle");

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

const INFURA_URL = "https://rinkeby.infura.io/v3/d76286c158cc4766b7cd59098d23c3b6"
// const INFURA_URL = "https://data-seed-prebsc-1-s1.binance.org:8545/"
const PRIVATE_KEY = "ec008d7e7874bd043403da58f4a1bf81e858d4a8abdd0af92f66bc6890a13589"

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  providerOptions: {
    allowUnlimitedContractSize: true
  },
  solidity: {
    version: "0.5.16",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1
      }
    }
  },
  networks: {
    hardhat: {
      blockGasLimit: 0x1fffffffffffff,
      gas: 12000000,
      allowUnlimitedContractSize: true,
      // url: INFURA_URL,
      // accounts: [`0x${PRIVATE_KEY}`],
      timeout: 1800000
    },
    rinkeby: {
      blockGasLimit: 0x1fffffffffffff,
      gas: 12000000,
      allowUnlimitedContractSize: true,
      url: INFURA_URL,
      accounts: [`0x${PRIVATE_KEY}`],
      timeout: 1800000
    }
  }
};

