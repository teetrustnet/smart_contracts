const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("MultiEpochAuctionApplicationMVP", function () {
  async function deployFixture() {
    const [owner, treasury, bidderA, bidderB] = await ethers.getSigners();

    const Auction = await ethers.getContractFactory("MultiEpochAuctionApplicationMVP");
    // For unit tests focused on auction accounting, sale token address can be any non-zero address.
    const auction = await Auction.deploy(treasury.address, treasury.address);
    await auction.waitForDeployment();

    return { owner, treasury, bidderA, bidderB, auction };
  }

  async function createConfiguredApplication(auction, owner, applicant, params = {}) {
    const totalEpochs = params.totalEpochs ?? 20;
    const epochDuration = params.epochDuration ?? 180;
    const commitDuration = params.commitDuration ?? 120;
    const revealDuration = params.revealDuration ?? 60;
    const maxQuantityPerBid = params.maxQuantityPerBid ?? 25_000;

    const appId = await auction
      .connect(owner)
      .createAuctionApplication.staticCall(
        applicant.address,
        "ipfs://auction-app",
        totalEpochs,
        epochDuration,
        commitDuration,
        revealDuration,
        maxQuantityPerBid,
      );

    await (
      await auction
        .connect(owner)
        .createAuctionApplication(
          applicant.address,
          "ipfs://auction-app",
          totalEpochs,
          epochDuration,
          commitDuration,
          revealDuration,
          maxQuantityPerBid,
        )
    ).wait();

    await (
      await auction.connect(owner).initializeEpochCurve(
        appId,
        ethers.parseEther("0.20"),
        5000,
        1_000_000,
        200,
      )
    ).wait();

    await (await auction.connect(owner).submitAuctionApplication(appId)).wait();
    await (await auction.connect(owner).approveAuctionApplication(appId)).wait();

    return appId;
  }

  it("supports application workflow + curve initialization", async function () {
    const { owner, bidderA, auction } = await deployFixture();

    const appId = await createConfiguredApplication(auction, owner, bidderA);

    const latest = await ethers.provider.getBlock("latest");
    const startTime = latest.timestamp + 30;
    await (await auction.connect(owner).launchAuctionApplication(appId, startTime)).wait();

    expect(await auction.activeApplicationId()).to.equal(appId);
    expect(await auction.totalEpochs()).to.equal(20);
    expect(await auction.epochDuration()).to.equal(180);
    expect(await auction.floorPriceForEpoch(1)).to.equal(ethers.parseEther("0.20"));
    expect(await auction.floorPriceForEpoch(20)).to.equal(ethers.parseEther("0.10"));

    const epoch20 = await auction.epochConfigFor(appId, 20);
    expect(epoch20.supplyTokens).to.equal(20_000);
  });

  it("supports one-step commit and finalization accounting", async function () {
    const { owner, bidderA, auction } = await deployFixture();

    const appId = await createConfiguredApplication(auction, owner, bidderA, {
      totalEpochs: 3,
      epochDuration: 180,
      commitDuration: 120,
      revealDuration: 60,
      maxQuantityPerBid: 50_000,
    });

    const latest = await ethers.provider.getBlock("latest");
    const startTime = latest.timestamp + 20;
    await (await auction.connect(owner).launchAuctionApplication(appId, startTime)).wait();

    await time.increaseTo(startTime + 1);

    const epochPrice = await auction.floorPriceForEpoch(1);
    const qty = 1_000n;
    const salt = ethers.id("direct-commit");

    await auction.connect(bidderA).commitBid(1, qty, epochPrice, salt, {
      value: qty * epochPrice,
    });

    const remaining = await auction.currentEpochRemainingTokens();
    const epoch1Config = await auction.epochConfigFor(appId, 1);
    expect(remaining).to.equal(epoch1Config.supplyTokens - qty);

    const summaryBeforeFinalize = await auction.getEpochSummary(1);
    expect(summaryBeforeFinalize[0]).to.equal(epochPrice);
    expect(summaryBeforeFinalize[1]).to.equal(qty);

    await time.increaseTo(startTime + 181);
    await (await auction.finalizeEpoch(1)).wait();

    const bid = await auction.getUserBid(bidderA.address, 1);
    expect(bid[4]).to.equal(qty);
    expect(bid[8]).to.equal(true);
  });

  it("keeps legacy commitBid(epochId, commitment) + revealBid compatibility", async function () {
    const { owner, bidderA, auction } = await deployFixture();

    const appId = await auction
      .connect(owner)
      .createAuctionApplication.staticCall(
        bidderA.address,
        "ipfs://legacy-app",
        2,
        180,
        120,
        60,
        10_000,
      );

    await (
      await auction
        .connect(owner)
        .createAuctionApplication(
          bidderA.address,
          "ipfs://legacy-app",
          2,
          180,
          120,
          60,
          10_000,
        )
    ).wait();

    await (
      await auction.connect(owner).setEpochConfigs(
        appId,
        [ethers.parseEther("0.30"), ethers.parseEther("0.15")],
        [1000, 500],
      )
    ).wait();

    await (await auction.connect(owner).submitAuctionApplication(appId)).wait();
    await (await auction.connect(owner).approveAuctionApplication(appId)).wait();

    const latest = await ethers.provider.getBlock("latest");
    const startTime = latest.timestamp + 20;
    await (await auction.connect(owner).launchAuctionApplication(appId, startTime)).wait();

    const qty = 40n;
    const price = ethers.parseEther("0.30");
    const salt = ethers.id("legacy-salt");
    const commitment = ethers.solidityPackedKeccak256(
      ["uint256", "address", "uint256", "uint256", "bytes32"],
      [1n, bidderA.address, qty, price, salt],
    );

    await time.increaseTo(startTime + 1);

    await auction.connect(bidderA)["commitBid(uint256,bytes32)"](1, commitment, {
      value: qty * price,
    });

    await time.increaseTo(startTime + 121);
    await (await auction.connect(bidderA).revealBid(1, qty, price, salt)).wait();

    await time.increaseTo(startTime + 181);
    await (await auction.finalizeEpoch(1)).wait();

    const bid = await auction.getUserBid(bidderA.address, 1);
    expect(bid[4]).to.equal(qty);
    expect(bid[8]).to.equal(true);
  });
});
