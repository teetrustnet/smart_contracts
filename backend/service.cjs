const { getBytes, hexlify } = require("ethers");

class LaunchConflictError extends Error {
  constructor(message) {
    super(message);
    this.name = "LaunchConflictError";
  }
}

function normalizeBytes(input) {
  if (typeof input !== "string" || input.length === 0) {
    throw new Error("Invalid bytes input");
  }

  if (input.startsWith("0x")) {
    getBytes(input); // validate
    return input;
  }

  // fallback: treat as base64
  const buf = Buffer.from(input, "base64");
  if (buf.length === 0) throw new Error("Unable to decode bytes input");
  return hexlify(buf);
}

async function launchFourMemeForApplication({
  applicationId,
  createTokenRequest,
  launchFeeWei,
  contract,
  fourMemeClient,
}) {
  const already = await contract.fourMemeLaunchExecuted(applicationId);
  if (already) {
    throw new LaunchConflictError(`application ${applicationId} already launched on four.meme`);
  }

  const payload = await fourMemeClient.createTokenPayload(createTokenRequest);
  const createArgs = normalizeBytes(payload.createArg);
  const signature = normalizeBytes(payload.signature);

  const tx = await contract.launchFourMemeToken(applicationId, createArgs, signature, {
    value: BigInt(launchFeeWei || "0"),
  });
  const receipt = await tx.wait();

  const launchedToken = await contract.launchedTokenByApplication(applicationId);

  return {
    applicationId,
    launchedToken,
    txHash: tx.hash,
    blockNumber: receipt?.blockNumber ?? null,
    requesterWallet: payload.accountAddress,
  };
}

module.exports = {
  LaunchConflictError,
  normalizeBytes,
  launchFourMemeForApplication,
};
