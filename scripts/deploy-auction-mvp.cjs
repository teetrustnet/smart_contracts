require("dotenv").config({ quiet: true });

const { ethers, network } = require("hardhat");

const ERC20_ABI = [
  "function balanceOf(address account) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
];

function readNumber(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;

  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`Invalid numeric value for ${name}: ${raw}`);
  }

  return value;
}

function readBigInt(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return BigInt(fallback);

  try {
    const value = BigInt(raw);
    if (value < 0n) throw new Error("negative");
    return value;
  } catch {
    throw new Error(`Invalid bigint value for ${name}: ${raw}`);
  }
}

function readAddress(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  if (!ethers.isAddress(raw)) throw new Error(`Invalid address for ${name}: ${raw}`);
  return raw;
}

function readEthPriceWei(name, fallbackEth) {
  const raw = process.env[name];
  const value = raw === undefined || raw === "" ? fallbackEth : raw;

  try {
    return ethers.parseEther(value);
  } catch {
    throw new Error(`Invalid ETH price for ${name}: ${value}`);
  }
}

function readBoolean(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;

  const normalized = raw.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;

  throw new Error(`Invalid boolean value for ${name}: ${raw}`);
}

async function main() {
  const signers = await ethers.getSigners();
  if (signers.length === 0) {
    throw new Error(
      `No deployer signer is available for '${network.name}'. Set DEPLOYER_PRIVATE_KEY for remote deployments.`,
    );
  }

  const [deployer] = signers;
  const treasuryAddress = readAddress("MVP_TREASURY", signers[1]?.address || deployer.address);

  console.log("Network:", network.name);
  console.log("Deploying with:", deployer.address);

  const now = (await ethers.provider.getBlock("latest")).timestamp;

  const totalEpochs = readNumber("MVP_TOTAL_EPOCHS", 20);
  const epochDuration = readNumber("MVP_EPOCH_SECONDS", 180);
  const commitDuration = readNumber("MVP_COMMIT_SECONDS", 120);
  const revealDuration = readNumber("MVP_REVEAL_SECONDS", 60);
  const maxQuantityPerBid = readBigInt("MVP_MAX_QTY", "25000");

  const firstEpochPriceWei = readEthPriceWei("MVP_FIRST_EPOCH_PRICE_ETH", "0.24");
  const lastEpochPriceBps = readNumber("MVP_LAST_EPOCH_PRICE_BPS", 5000);

  const totalAuctionSupplyTokens = readBigInt("MVP_TOTAL_AUCTION_SUPPLY", "50000000");
  const lastEpochSupplyBps = readNumber("MVP_LAST_EPOCH_SUPPLY_BPS", 200);

  const startDelaySeconds = readNumber("MVP_START_DELAY_SECONDS", 120);
  const startTime = readNumber("MVP_START_TIME", now + startDelaySeconds);

  const tokenAddress = readAddress("MVP_SALE_TOKEN_ADDRESS", ethers.ZeroAddress);
  const fourMemeTokenManager = readAddress("MVP_FOUR_MEME_TOKEN_MANAGER", ethers.ZeroAddress);
  const token = tokenAddress === ethers.ZeroAddress ? null : new ethers.Contract(tokenAddress, ERC20_ABI, deployer);
  const seedAuctionWithTokens = readBoolean("MVP_SEED_AUCTION_WITH_TOKENS", false);

  const Auction = await ethers.getContractFactory("MultiEpochAuctionApplicationMVP");
  const auction = await Auction.deploy(tokenAddress, treasuryAddress);
  await auction.waitForDeployment();

  if (fourMemeTokenManager !== ethers.ZeroAddress) {
    await (await auction.setFourMemeTokenManager(fourMemeTokenManager)).wait();
  }

  const appId = await auction
    .createAuctionApplication.staticCall(
      deployer.address,
      process.env.MVP_METADATA_URI || "ipfs://trustnet-auction-application",
      totalEpochs,
      epochDuration,
      commitDuration,
      revealDuration,
      maxQuantityPerBid,
    );

  await (
    await auction.createAuctionApplication(
      deployer.address,
      process.env.MVP_METADATA_URI || "ipfs://trustnet-auction-application",
      totalEpochs,
      epochDuration,
      commitDuration,
      revealDuration,
      maxQuantityPerBid,
    )
  ).wait();

  await (
    await auction.initializeEpochCurve(
      appId,
      firstEpochPriceWei,
      lastEpochPriceBps,
      totalAuctionSupplyTokens,
      lastEpochSupplyBps,
    )
  ).wait();

  await (await auction.submitAuctionApplication(appId)).wait();
  await (await auction.approveAuctionApplication(appId)).wait();
  await (await auction.launchAuctionApplication(appId, startTime)).wait();

  if (seedAuctionWithTokens) {
    if (!token) {
      throw new Error("MVP_SALE_TOKEN_ADDRESS is required when MVP_SEED_AUCTION_WITH_TOKENS=true");
    }

    const transferAmount = totalAuctionSupplyTokens * 10n ** 18n;
    const deployerBalance = await token.balanceOf(deployer.address);
    if (deployerBalance < transferAmount) {
      throw new Error(
        `Deployer token balance ${deployerBalance} is below required auction inventory ${transferAmount}.`,
      );
    }

    await (await token.transfer(await auction.getAddress(), transferAmount)).wait();
  }

  console.log("SaleToken:", tokenAddress);
  console.log("FourMemeTokenManager:", fourMemeTokenManager);
  console.log("MultiEpochAuctionApplicationMVP:", await auction.getAddress());
  console.log("Treasury:", treasuryAddress);
  console.log("ApplicationId:", appId.toString());
  console.log("Auction Start:", startTime);
  console.log("Inventory Seeded:", seedAuctionWithTokens ? "yes" : "no");
  console.log("Total Auction Supply (whole tokens):", totalAuctionSupplyTokens.toString());
  console.log("Max Quantity Per Bid (whole tokens):", maxQuantityPerBid.toString());
  console.log("First Epoch Price (wei):", firstEpochPriceWei.toString());
  console.log("Last Epoch Price Bps:", lastEpochPriceBps);
  console.log("Last Epoch Supply Bps:", lastEpochSupplyBps);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
