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

function readTokenAmount(name, fallback) {
  const raw = process.env[name];
  const value = raw === undefined || raw === "" ? fallback : raw;

  try {
    return ethers.parseUnits(value, 18);
  } catch {
    throw new Error(`Invalid 18-decimal token amount for ${name}: ${value}`);
  }
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

function readAddress(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  if (!ethers.isAddress(raw)) throw new Error(`Invalid address for ${name}: ${raw}`);
  return raw;
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
  const treasuryAddress = readAddress("FIXED_TREASURY", signers[1]?.address || deployer.address);

  console.log("Network:", network.name);
  console.log("Deploying with:", deployer.address);

  const now = (await ethers.provider.getBlock("latest")).timestamp;

  const totalEpochs = readNumber("FIXED_TOTAL_EPOCHS", 30);
  const epochDuration = readNumber("FIXED_EPOCH_SECONDS", 120);
  const tokensPerEpoch = readTokenAmount("FIXED_TOKENS_PER_EPOCH", "25000");
  const maxQuantityPerOrder = readTokenAmount("FIXED_MAX_QTY", "25000");

  const initialPriceWei = readEthPriceWei("FIXED_INITIAL_PRICE_ETH", "0.24");
  const reservePriceWei = readEthPriceWei("FIXED_RESERVE_PRICE_ETH", "0.06");
  const priceDecayBps = readNumber("FIXED_PRICE_DECAY_BPS", 200);

  const startDelaySeconds = readNumber("FIXED_START_DELAY_SECONDS", 120);
  const auctionStartTime = readNumber("FIXED_START_TIME", now + startDelaySeconds);

  const existingTokenAddress = readAddress("FIXED_SALE_TOKEN_ADDRESS");
  const mintMultiplier = readBigInt("FIXED_MINT_MULTIPLIER", "2");
  const seedAuctionWithTokens = readBoolean("FIXED_SEED_AUCTION_WITH_TOKENS", !existingTokenAddress);

  // Optional listing metadata bootstrap
  const bootstrapListing = readBoolean("FIXED_BOOTSTRAP_LISTING", false);
  const listingAgentId = readBigInt("FIXED_AGENT_ID", "8004");
  const listingAgentOwner = readAddress("FIXED_AGENT_OWNER", deployer.address);
  const listingTicker = process.env.FIXED_TICKER || "$WAIFU";
  const listingWebsite = process.env.FIXED_PROJECT_WEBSITE || "https://waifu.example";
  const listingX = process.env.FIXED_PROJECT_X || "https://x.com/waifu";
  const listingAgentURI = process.env.FIXED_AGENT_URI || "ipfs://waifu-agent";
  const listingAttHashInput = process.env.FIXED_ATTESTATION_HASH || "attestation-v1";
  const listingAttestationHash = listingAttHashInput.startsWith("0x")
    ? listingAttHashInput
    : ethers.keccak256(ethers.toUtf8Bytes(listingAttHashInput));

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

  const Auction = await ethers.getContractFactory("MultiEpochFixedPriceAuction");
  const auction = await Auction.deploy(
    tokenAddress,
    treasuryAddress,
    auctionStartTime,
    totalEpochs,
    epochDuration,
    tokensPerEpoch,
    maxQuantityPerOrder,
    initialPriceWei,
    reservePriceWei,
    priceDecayBps,
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

  if (bootstrapListing) {
    await (
      await auction.configureListing(
        listingAgentId,
        listingAgentOwner,
        listingTicker,
        listingWebsite,
        listingX,
        listingAgentURI,
        listingAttestationHash,
      )
    ).wait();

    await (await auction.setAttestationVerification(true, auctionStartTime)).wait();
    await (await auction.activateListing()).wait();
  }

  console.log("SaleToken:", tokenAddress);
  console.log("SaleTokenMode:", tokenMode);
  console.log("MultiEpochFixedPriceAuction:", await auction.getAddress());
  console.log("Treasury:", treasuryAddress);
  console.log("Auction Start:", auctionStartTime);
  console.log("Inventory Seeded:", seedAuctionWithTokens ? "yes" : "no");
  console.log("Listing Bootstrapped:", bootstrapListing ? "yes" : "no");
  console.log("Total Auction Inventory:", ethers.formatUnits(totalSupplyForAuction, 18));
  console.log("Max Quantity Per Order:", ethers.formatUnits(maxQuantityPerOrder, 18));
  console.log("Initial Price (wei):", initialPriceWei.toString());
  console.log("Reserve Price (wei):", reservePriceWei.toString());
  console.log("Price Decay (bps/epoch):", priceDecayBps);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
