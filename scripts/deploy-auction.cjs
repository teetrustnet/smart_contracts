const { ethers } = require("hardhat");

async function main() {
  const [deployer, treasury] = await ethers.getSigners();

  console.log("Deploying with:", deployer.address);

  const now = (await ethers.provider.getBlock("latest")).timestamp;

  const totalEpochs = Number(process.env.AUCTION_TOTAL_EPOCHS || 10);
  const commitDuration = Number(process.env.AUCTION_COMMIT_SECONDS || 300);
  const revealDuration = Number(process.env.AUCTION_REVEAL_SECONDS || 120);
  const tokensPerEpoch = BigInt(process.env.AUCTION_TOKENS_PER_EPOCH || "25000");
  const maxQuantityPerBid = BigInt(process.env.AUCTION_MAX_QTY || "25000");
  const initialFloorPriceWei = ethers.parseEther(process.env.AUCTION_INITIAL_FLOOR_ETH || "0.24");
  const penaltyBps = Number(process.env.AUCTION_PENALTY_BPS || 500);

  const auctionStartTime = Number(process.env.AUCTION_START_TIME || now + 120);

  const MockSaleToken = await ethers.getContractFactory("MockSaleToken");
  const token = await MockSaleToken.deploy();
  await token.waitForDeployment();

  const totalSupplyForAuction = tokensPerEpoch * BigInt(totalEpochs);
  const mintAmount = totalSupplyForAuction * 2n;
  await (await token.mint(deployer.address, mintAmount)).wait();

  const MultiEpochVickreyAuction = await ethers.getContractFactory("MultiEpochVickreyAuction");
  const auction = await MultiEpochVickreyAuction.deploy(
    await token.getAddress(),
    treasury.address,
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

  await (await token.transfer(await auction.getAddress(), totalSupplyForAuction)).wait();

  console.log("MockSaleToken:", await token.getAddress());
  console.log("MultiEpochVickreyAuction:", await auction.getAddress());
  console.log("Treasury:", treasury.address);
  console.log("Auction Start:", auctionStartTime);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
