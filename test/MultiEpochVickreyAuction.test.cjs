const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("MultiEpochVickreyAuction", function () {
  async function deployFixture() {
    const [owner, treasury, bidderA, bidderB] = await ethers.getSigners();

    const MockSaleToken = await ethers.getContractFactory("MockSaleToken");
    const token = await MockSaleToken.deploy();
    await token.waitForDeployment();

    const latest = await ethers.provider.getBlock("latest");
    const auctionStart = latest.timestamp + 60;

    const params = {
      totalEpochs: 3,
      commitDuration: 300,
      revealDuration: 120,
      tokensPerEpoch: 1000n,
      maxQuantityPerBid: 1000n,
      initialFloor: ethers.parseEther("0.10"),
      penaltyBps: 500,
    };

    const Auction = await ethers.getContractFactory("MultiEpochVickreyAuction");
    const auction = await Auction.deploy(
      await token.getAddress(),
      treasury.address,
      auctionStart,
      params.totalEpochs,
      params.commitDuration,
      params.revealDuration,
      params.tokensPerEpoch,
      params.maxQuantityPerBid,
      params.initialFloor,
      params.penaltyBps,
    );
    await auction.waitForDeployment();

    const inventory = params.tokensPerEpoch * BigInt(params.totalEpochs);
    await (await token.mint(owner.address, inventory * 2n)).wait();
    await (await token.transfer(await auction.getAddress(), inventory)).wait();

    return { owner, treasury, bidderA, bidderB, token, auction, auctionStart, params };
  }

  it("handles commit/reveal/finalize/claim/refund lifecycle", async function () {
    const { auction, token, bidderA, bidderB, auctionStart, params } = await deployFixture();

    await time.increaseTo(auctionStart + 1);

    const qtyA = 600n;
    const qtyB = 500n;
    const priceA = ethers.parseEther("0.20");
    const priceB = ethers.parseEther("0.15");
    const saltA = ethers.id("salt-A");
    const saltB = ethers.id("salt-B");

    const commitmentA = ethers.solidityPackedKeccak256(
      ["uint256", "address", "uint256", "uint256", "bytes32"],
      [1n, bidderA.address, qtyA, priceA, saltA],
    );
    const commitmentB = ethers.solidityPackedKeccak256(
      ["uint256", "address", "uint256", "uint256", "bytes32"],
      [1n, bidderB.address, qtyB, priceB, saltB],
    );

    await auction.connect(bidderA).commitBid(1, commitmentA, { value: qtyA * priceA });
    await auction.connect(bidderB).commitBid(1, commitmentB, { value: qtyB * priceB });

    await time.increaseTo(auctionStart + params.commitDuration + 1);

    await auction.connect(bidderA).revealBid(1, qtyA, priceA, saltA);
    await auction.connect(bidderB).revealBid(1, qtyB, priceB, saltB);

    await time.increaseTo(auctionStart + params.commitDuration + params.revealDuration + 1);

    await auction.finalizeEpoch(1);

    const summary = await auction.getEpochSummary(1);
    expect(summary[0]).to.equal(priceB);
    expect(summary[1]).to.equal(1000n);
    expect(summary[2]).to.equal(priceB / 2n);

    const bidA = await auction.getUserBid(bidderA.address, 1);
    const bidB = await auction.getUserBid(bidderB.address, 1);

    expect(bidA[4]).to.equal(600n);
    expect(bidB[4]).to.equal(400n);
    expect(bidA[6]).to.equal(ethers.parseEther("30"));
    expect(bidB[6]).to.equal(ethers.parseEther("15"));

    await auction.connect(bidderA).claimTokens([1]);
    await auction.connect(bidderB).claimTokens([1]);

    expect(await token.balanceOf(bidderA.address)).to.equal(600n);
    expect(await token.balanceOf(bidderB.address)).to.equal(400n);

    await auction.connect(bidderA).withdrawRefund(1);
    await auction.connect(bidderB).withdrawRefund(1);

    const bidAAfter = await auction.getUserBid(bidderA.address, 1);
    const bidBAfter = await auction.getUserBid(bidderB.address, 1);

    expect(bidAAfter[9]).to.equal(true);
    expect(bidBAfter[9]).to.equal(true);
  });

  it("applies non-reveal penalty and leaves refundable remainder", async function () {
    const { auction, bidderA, auctionStart, params } = await deployFixture();

    await time.increaseTo(auctionStart + 1);

    const qty = 80n;
    const price = ethers.parseEther("0.12");
    const collateral = qty * price;
    const salt = ethers.id("salt-missed");

    const commitment = ethers.solidityPackedKeccak256(
      ["uint256", "address", "uint256", "uint256", "bytes32"],
      [1n, bidderA.address, qty, price, salt],
    );

    await auction.connect(bidderA).commitBid(1, commitment, { value: collateral });

    await time.increaseTo(auctionStart + params.commitDuration + params.revealDuration + 1);
    await auction.finalizeEpoch(1);

    const bid = await auction.getUserBid(bidderA.address, 1);

    const expectedPenalty = (collateral * BigInt(params.penaltyBps)) / 10_000n;
    const expectedRefund = collateral - expectedPenalty;

    expect(bid[6]).to.equal(expectedRefund);
    expect(await auction.treasuryAccrued()).to.equal(expectedPenalty);
  });
});
