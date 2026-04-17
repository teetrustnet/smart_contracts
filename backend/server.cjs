const express = require("express");
const { JsonRpcProvider, Wallet, Contract } = require("ethers");
const { env, intEnv } = require("./config.cjs");
const { FourMemeClient } = require("./fourmeme-client.cjs");
const { LaunchConflictError, launchFourMemeForApplication } = require("./service.cjs");

const AUCTION_ABI = [
  "function fourMemeLaunchExecuted(uint256) view returns (bool)",
  "function launchFourMemeToken(uint256 applicationId, bytes createArgs, bytes signature) payable",
  "function launchedTokenByApplication(uint256) view returns (address)",
];

function createTaskQueue(concurrency = 1) {
  let active = 0;
  const pending = [];

  const pump = () => {
    while (active < concurrency && pending.length > 0) {
      const item = pending.shift();
      active += 1;

      Promise.resolve()
        .then(item.task)
        .then(item.resolve, item.reject)
        .finally(() => {
          active -= 1;
          pump();
        });
    }
  };

  return {
    get size() {
      return pending.length;
    },
    get active() {
      return active;
    },
    enqueue(task) {
      return new Promise((resolve, reject) => {
        pending.push({ task, resolve, reject });
        pump();
      });
    },
  };
}

async function main() {
  const app = express();
  app.use(express.json({ limit: "2mb" }));

  const rpcUrl = env("BACKEND_RPC_URL");
  const backendPk = env("BACKEND_SIGNER_PRIVATE_KEY");
  const auctionAddress = env("BACKEND_AUCTION_CONTRACT");

  const provider = new JsonRpcProvider(rpcUrl);
  const signer = new Wallet(backendPk, provider);
  const contract = new Contract(auctionAddress, AUCTION_ABI, signer);

  const fourMemeClient = new FourMemeClient({
    baseUrl: env("FOUR_MEME_BASE_URL", "https://four.meme/meme-api"),
    privateKey: env("FOUR_MEME_LOGIN_PRIVATE_KEY", backendPk),
    networkCode: env("FOUR_MEME_NETWORK_CODE", "BSC"),
    region: env("FOUR_MEME_REGION", "WEB"),
    langType: env("FOUR_MEME_LANG", "EN"),
    walletName: env("FOUR_MEME_WALLET_NAME", "TrustNetBackend"),
    accessTokenTtlMs: intEnv("FOUR_MEME_ACCESS_TOKEN_TTL_MS", 50 * 60 * 1000),
    maxRetries: intEnv("FOUR_MEME_MAX_RETRIES", 3),
    retryBaseMs: intEnv("FOUR_MEME_RETRY_BASE_MS", 800),
  });

  const queueConcurrency = Math.max(1, intEnv("BACKEND_LAUNCH_QUEUE_CONCURRENCY", 1));
  const launchQueue = createTaskQueue(queueConcurrency);
  const inFlightByApplication = new Map();

  app.get("/healthz", async (_req, res) => {
    const block = await provider.getBlockNumber();
    res.json({
      ok: true,
      block,
      signer: signer.address,
      queue: {
        active: launchQueue.active,
        pending: launchQueue.size,
        inFlightApplications: inFlightByApplication.size,
      },
    });
  });

  app.post("/auction/:applicationId/fourmeme/launch", async (req, res) => {
    const applicationId = Number(req.params.applicationId);
    if (!Number.isInteger(applicationId) || applicationId <= 0) {
      return res.status(400).json({ error: "invalid applicationId" });
    }

    const { createTokenRequest, launchFeeWei = "0" } = req.body || {};
    if (!createTokenRequest || typeof createTokenRequest !== "object") {
      return res.status(400).json({ error: "createTokenRequest is required" });
    }

    if (inFlightByApplication.has(applicationId)) {
      return res.status(409).json({
        ok: false,
        error: `launch already in progress for application ${applicationId}`,
      });
    }

    try {
      const alreadyLaunched = await contract.fourMemeLaunchExecuted(applicationId);
      if (alreadyLaunched) {
        const launchedToken = await contract.launchedTokenByApplication(applicationId);
        return res.status(409).json({
          ok: false,
          error: `application ${applicationId} already launched on four.meme`,
          launchedToken,
        });
      }

      const launchPromise = launchQueue.enqueue(() =>
        launchFourMemeForApplication({
          applicationId,
          createTokenRequest,
          launchFeeWei,
          contract,
          fourMemeClient,
        }),
      );

      inFlightByApplication.set(applicationId, launchPromise);
      const result = await launchPromise;
      return res.json({ ok: true, result });
    } catch (error) {
      if (error instanceof LaunchConflictError) {
        const launchedToken = await contract.launchedTokenByApplication(applicationId);
        return res.status(409).json({
          ok: false,
          error: error.message,
          launchedToken,
        });
      }

      const message = error instanceof Error ? error.message : "unknown error";
      return res.status(500).json({ ok: false, error: message });
    } finally {
      inFlightByApplication.delete(applicationId);
    }
  });

  const port = intEnv("BACKEND_PORT", 8787);
  app.listen(port, () => {
    // eslint-disable-next-line no-console
    console.log(`[fourmeme-backend] listening on :${port}`);
  });
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});
