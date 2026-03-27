const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("MultiEpochFixedPriceAuction", function () {
  const unit = (value) => ethers.parseUnits(value, 18);
  const quote = (quantity, pricePerToken) => (quantity * pricePerToken) / unit("1");

  async function deployFixture() {
    const [owner, treasury, bidderA, bidderB] = await ethers.getSigners();

    const MockSaleToken = await ethers.getContractFactory("MockSaleToken");
    const token = await MockSaleToken.deploy();
    await token.waitForDeployment();

    const latest = await ethers.provider.getBlock("latest");
    const auctionStart = latest.timestamp + 60;

    const params = {
      totalEpochs: 2,
      epochDuration: 120,
      tokensPerEpoch: unit("1000"),
      maxQty: unit("1000"),
      initialPrice: ethers.parseEther("0.10"),
      reservePrice: ethers.parseEther("0.04"),
      priceDecayBps: 0,
    };

    const Auction = await ethers.getContractFactory("MultiEpochFixedPriceAuction");
    const auction = await Auction.deploy(
      await token.getAddress(),
      treasury.address,
      auctionStart,
      params.totalEpochs,
      params.epochDuration,
      params.tokensPerEpoch,
      params.maxQty,
      params.initialPrice,
      params.reservePrice,
      params.priceDecayBps,
    );
    await auction.waitForDeployment();

    const inventory = params.tokensPerEpoch * BigInt(params.totalEpochs);
    await (await token.mint(owner.address, inventory * 2n)).wait();
    await (await token.transfer(await auction.getAddress(), inventory)).wait();

    return { owner, treasury, bidderA, bidderB, token, auction, auctionStart, params };
  }

  async function activateListing(auction, owner, atTime) {
    const attestationHash = ethers.keccak256(ethers.toUtf8Bytes("attestation-v1"));

    await (
      await auction
        .connect(owner)
        .configureListing(
          8004n,
          owner.address,
          "$WAIFU",
          "https://waifu.example",
          "https://x.com/waifu",
          "ipfs://waifu-agent",
          attestationHash,
        )
    ).wait();

    await (await auction.connect(owner).setAttestationVerification(true, atTime)).wait();
    await (await auction.connect(owner).activateListing()).wait();
  }

  it("supports fixed-price order -> finalize -> claim/refund lifecycle with tip-priority fill", async function () {
    const { owner, bidderA, bidderB, auction, token, auctionStart, params } = await deployFixture();

    await activateListing(auction, owner, BigInt(auctionStart));

    await time.increaseTo(auctionStart + 1);

    const qtyA = unit("700");
    const qtyB = unit("700");
    const epochPrice = params.initialPrice;

    const tipA = 200; // 2%
    const tipB = 1000; // 10%

    const paymentA = quote(qtyA, epochPrice);
    const paymentB = quote(qtyB, epochPrice);

    const tipAmountA = (paymentA * BigInt(tipA)) / 10_000n;
    const tipAmountB = (paymentB * BigInt(tipB)) / 10_000n;

    await auction.connect(bidderA).placeOrder(1, qtyA, tipA, { value: paymentA + tipAmountA });
    await auction.connect(bidderB).placeOrder(1, qtyB, tipB, { value: paymentB + tipAmountB });

    await time.increaseTo(auctionStart + params.epochDuration + 1);
    await auction.finalizeEpoch(1);

    const summary = await auction.getEpochSummary(1);
    expect(summary.pricePerToken).to.equal(epochPrice);
    expect(summary.tokensSold).to.equal(unit("1000"));

    const orderA = await auction.getOrder(bidderA.address, 1);
    const orderB = await auction.getOrder(bidderB.address, 1);

    // bidderB has higher tip bps, so bidderB gets filled first
    expect(orderB.allocatedQuantity).to.equal(unit("700"));
    expect(orderA.allocatedQuantity).to.equal(unit("300"));

    // bidderA should have refund on unfilled portion
    expect(orderA.refundDue).to.be.gt(0n);

    await auction.connect(bidderA).claimTokens([1]);
    await auction.connect(bidderB).claimTokens([1]);

    expect(await token.balanceOf(bidderA.address)).to.equal(unit("300"));
    expect(await token.balanceOf(bidderB.address)).to.equal(unit("700"));

    await auction.connect(bidderA).withdrawRefund(1);
    await expect(auction.connect(bidderB).withdrawRefund(1)).to.be.revertedWithCustomError(
      auction,
      "NothingToWithdraw",
    );
  });

  it("blocks orders when listing is not active", async function () {
    const { auction, bidderA, auctionStart, params } = await deployFixture();

    await time.increaseTo(auctionStart + 1);

    const qty = unit("10");
    const payment = quote(qty, params.initialPrice);
    const tip = (payment * 200n) / 10_000n;

    await expect(
      auction.connect(bidderA).placeOrder(1, qty, 200, { value: payment + tip }),
    ).to.be.revertedWithCustomError(auction, "ListingNotActive");
  });

  it("uses geometric decay curve with reserve floor", async function () {
    const [owner, treasury] = await ethers.getSigners();

    const MockSaleToken = await ethers.getContractFactory("MockSaleToken");
    const token = await MockSaleToken.deploy();
    await token.waitForDeployment();

    const latest = await ethers.provider.getBlock("latest");
    const auctionStart = latest.timestamp + 60;

    const Auction = await ethers.getContractFactory("MultiEpochFixedPriceAuction");
    const auction = await Auction.deploy(
      await token.getAddress(),
      treasury.address,
      auctionStart,
      8,
      120,
      unit("100"),
      unit("100"),
      ethers.parseEther("1"), // initial
      ethers.parseEther("0.25"), // reserve floor
      2000, // 20% geometric decay per epoch
    );
    await auction.waitForDeployment();

    expect(await auction.epochPriceFor(1)).to.equal(ethers.parseEther("1"));
    expect(await auction.epochPriceFor(2)).to.equal(ethers.parseEther("0.8"));
    expect(await auction.epochPriceFor(3)).to.equal(ethers.parseEther("0.64"));

    // by later epochs, price should not go below reserve floor
    const p7 = await auction.epochPriceFor(7);
    expect(p7).to.equal(ethers.parseEther("0.262144"));

    const p8 = await auction.epochPriceFor(8);
    expect(p8).to.equal(ethers.parseEther("0.25"));

    const batch = await auction.getEpochPriceBatch(1, 4);
    expect(batch.length).to.equal(4);
    expect(batch[0]).to.equal(ethers.parseEther("1"));
    expect(batch[1]).to.equal(ethers.parseEther("0.8"));
    expect(batch[2]).to.equal(ethers.parseEther("0.64"));
    expect(batch[3]).to.equal(ethers.parseEther("0.512"));
  });
});
