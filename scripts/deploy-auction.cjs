require("dotenv").config({ quiet: true });

const { ethers, network } = require("hardhat");

const ERC20_ABI = [
  "function balanceOf(address account) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
];

function readNumber(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") {
    return fallback;
  }

  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`Invalid numeric value for ${name}: ${raw}`);
  }

  return value;
}

function readBigInt(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") {
    return BigInt(fallback);
  }

  try {
    const value = BigInt(raw);
    if (value < 0n) {
      throw new Error("negative");
    }
    return value;
  } catch {
    throw new Error(`Invalid bigint value for ${name}: ${raw}`);
  }
}

function readBoolean(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") {
    return fallback;
  }

  const normalized = raw.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) {
    return true;
  }
  if (["0", "false", "no", "off"].includes(normalized)) {
    return false;
  }

  throw new Error(`Invalid boolean value for ${name}: ${raw}`);
}

function readAddress(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") {
    return fallback;
  }

  if (!ethers.isAddress(raw)) {
    throw new Error(`Invalid address for ${name}: ${raw}`);
  }

  return raw;
}

async function main() {
  const signers = await ethers.getSigners();
  if (signers.length === 0) {
    throw new Error(
      `No deployer signer is available for '${network.name}'. Set DEPLOYER_PRIVATE_KEY for remote deployments.`,
    );
  }

  const [deployer] = signers;
  const treasuryAddress = readAddress(
    "AUCTION_TREASURY",
    signers[1]?.address || deployer.address,
  );

  console.log("Network:", network.name);
  console.log("Deploying with:", deployer.address);

  const now = (await ethers.provider.getBlock("latest")).timestamp;

  const totalEpochs = readNumber("AUCTION_TOTAL_EPOCHS", 10);
  const commitDuration = readNumber("AUCTION_COMMIT_SECONDS", 300);
  const revealDuration = readNumber("AUCTION_REVEAL_SECONDS", 120);
  const tokensPerEpoch = readBigInt("AUCTION_TOKENS_PER_EPOCH", "25000");
  const maxQuantityPerBid = readBigInt("AUCTION_MAX_QTY", "25000");
  const initialFloorPriceWei = ethers.parseEther(process.env.AUCTION_INITIAL_FLOOR_ETH || "0.24");
  const penaltyBps = readNumber("AUCTION_PENALTY_BPS", 500);
  const startDelaySeconds = readNumber("AUCTION_START_DELAY_SECONDS", 120);
  const existingTokenAddress = readAddress("AUCTION_SALE_TOKEN_ADDRESS");
  const mintMultiplier = readBigInt("AUCTION_MINT_MULTIPLIER", "2");
  const seedAuctionWithTokens = readBoolean(
    "AUCTION_SEED_AUCTION_WITH_TOKENS",
    !existingTokenAddress,
  );

  const auctionStartTime = readNumber("AUCTION_START_TIME", now + startDelaySeconds);

  const totalSupplyForAuction = tokensPerEpoch * BigInt(totalEpochs);
  let token;
  let tokenAddress;
  let tokenMode;

  if (existingTokenAddress) {
    tokenAddress = existingTokenAddress;
    token = new ethers.Contract(existingTokenAddress, ERC20_ABI, deployer);
    tokenMode = "existing";
  } else {
    const MockSaleToken = await ethers.getContractFactory("MockSaleToken");
    token = await MockSaleToken.deploy();
    await token.waitForDeployment();

    tokenAddress = await token.getAddress();
    tokenMode = "mock";

    const mintAmount = totalSupplyForAuction * mintMultiplier;
    await (await token.mint(deployer.address, mintAmount)).wait();
  }

  const MultiEpochVickreyAuction = await ethers.getContractFactory("MultiEpochVickreyAuction");
  const auction = await MultiEpochVickreyAuction.deploy(
    tokenAddress,
    treasuryAddress,
    auctionStartTime,
    totalEpochs,
    commitDuration,
    revealDuration,
    tokensPerEpoch,
    maxQuantityPerBid,
    initialFloorPriceWei,
    penaltyBps,
  );
  await auction.waitForDeployment();

  if (seedAuctionWithTokens) {
    const deployerBalance = await token.balanceOf(deployer.address);
    if (deployerBalance < totalSupplyForAuction) {
      throw new Error(
        `Deployer token balance ${deployerBalance} is below required auction inventory ${totalSupplyForAuction}.`,
      );
    }

    await (await token.transfer(await auction.getAddress(), totalSupplyForAuction)).wait();
  }

  console.log("SaleToken:", tokenAddress);
  console.log("SaleTokenMode:", tokenMode);
  console.log("MultiEpochVickreyAuction:", await auction.getAddress());
  console.log("Treasury:", treasuryAddress);
  console.log("Auction Start:", auctionStartTime);
  console.log("Inventory Seeded:", seedAuctionWithTokens ? "yes" : "no");
  console.log("Total Auction Inventory:", totalSupplyForAuction.toString());
  console.log("Initial Floor Price (wei):", initialFloorPriceWei.toString());

  if (!seedAuctionWithTokens) {
    console.log("Next Step: transfer sale token inventory to the auction contract before opening bidding.");
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
