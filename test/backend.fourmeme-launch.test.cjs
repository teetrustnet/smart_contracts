const test = require("node:test");
const assert = require("node:assert/strict");

const { LaunchConflictError, launchFourMemeForApplication, normalizeBytes } = require("../backend/service.cjs");

test("normalizeBytes accepts hex and base64", () => {
  assert.equal(normalizeBytes("0x1234"), "0x1234");
  assert.equal(normalizeBytes(Buffer.from([0x12, 0x34]).toString("base64")), "0x1234");
});

test("launchFourMemeForApplication success path", async () => {
  const calls = [];

  const contract = {
    async fourMemeLaunchExecuted(appId) {
      assert.equal(appId, 1);
      return false;
    },
    async launchFourMemeToken(appId, createArgs, signature, opts) {
      calls.push({ appId, createArgs, signature, opts });
      return {
        hash: "0xtx",
        async wait() {
          return { blockNumber: 123 };
        },
      };
    },
    async launchedTokenByApplication(appId) {
      assert.equal(appId, 1);
      return "0x1111111111111111111111111111111111111111";
    },
  };

  const fourMemeClient = {
    async createTokenPayload() {
      return {
        createArg: "0xaaaa",
        signature: "0xbbbb",
        accountAddress: "0x2222222222222222222222222222222222222222",
      };
    },
  };

  const out = await launchFourMemeForApplication({
    applicationId: 1,
    createTokenRequest: { name: "TEST" },
    launchFeeWei: "7",
    contract,
    fourMemeClient,
  });

  assert.equal(out.txHash, "0xtx");
  assert.equal(out.blockNumber, 123);
  assert.equal(out.launchedToken, "0x1111111111111111111111111111111111111111");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].opts.value, 7n);
});

test("launchFourMemeForApplication rejects duplicate launches", async () => {
  const contract = {
    async fourMemeLaunchExecuted() {
      return true;
    },
  };

  const fourMemeClient = {
    async createTokenPayload() {
      throw new Error("should not be called");
    },
  };

  await assert.rejects(
    () =>
      launchFourMemeForApplication({
        applicationId: 2,
        createTokenRequest: {},
        launchFeeWei: "0",
        contract,
        fourMemeClient,
      }),
    (err) => err instanceof LaunchConflictError,
  );
});
