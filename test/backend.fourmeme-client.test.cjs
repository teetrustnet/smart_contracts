const test = require("node:test");
const assert = require("node:assert/strict");

const { FourMemeClient } = require("../backend/fourmeme-client.cjs");

const TEST_PRIVATE_KEY = "0x59c6995e998f97a5a0044966f094538e0f7f9b52f6f4e6f1e9a2b96f8aeeccf1";

function createMockResponse(status, body, headers = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: {
      get(name) {
        return headers[name.toLowerCase()] ?? null;
      },
    },
    async text() {
      return JSON.stringify(body);
    },
  };
}

test("FourMemeClient caches access token between launches", async () => {
  const originalFetch = global.fetch;
  const counters = { nonce: 0, login: 0, create: 0 };

  global.fetch = async (url) => {
    if (url.includes("/nonce/generate")) {
      counters.nonce += 1;
      return createMockResponse(200, { code: "0", data: `nonce-${counters.nonce}` });
    }

    if (url.includes("/login/dex")) {
      counters.login += 1;
      return createMockResponse(200, { code: "0", data: "access-token" });
    }

    if (url.includes("/token/create")) {
      counters.create += 1;
      return createMockResponse(200, {
        code: "0",
        data: { createArg: "0xaaaa", signature: "0xbbbb" },
      });
    }

    throw new Error(`unexpected URL: ${url}`);
  };

  try {
    const client = new FourMemeClient({
      baseUrl: "https://four.meme/meme-api",
      privateKey: TEST_PRIVATE_KEY,
      accessTokenTtlMs: 60_000,
      maxRetries: 0,
    });

    await client.createTokenPayload({ name: "A" });
    await client.createTokenPayload({ name: "B" });

    assert.equal(counters.nonce, 1);
    assert.equal(counters.login, 1);
    assert.equal(counters.create, 2);
  } finally {
    global.fetch = originalFetch;
  }
});

test("FourMemeClient retries token/create on 429", async () => {
  const originalFetch = global.fetch;
  const counters = { nonce: 0, login: 0, create: 0 };

  global.fetch = async (url) => {
    if (url.includes("/nonce/generate")) {
      counters.nonce += 1;
      return createMockResponse(200, { code: "0", data: "nonce-retry" });
    }

    if (url.includes("/login/dex")) {
      counters.login += 1;
      return createMockResponse(200, { code: "0", data: "access-token" });
    }

    if (url.includes("/token/create")) {
      counters.create += 1;
      if (counters.create === 1) {
        return createMockResponse(429, { code: "429", message: "rate limit" }, { "retry-after": "0" });
      }

      return createMockResponse(200, {
        code: "0",
        data: { createArg: "0xaaaa", signature: "0xbbbb" },
      });
    }

    throw new Error(`unexpected URL: ${url}`);
  };

  try {
    const client = new FourMemeClient({
      baseUrl: "https://four.meme/meme-api",
      privateKey: TEST_PRIVATE_KEY,
      maxRetries: 2,
      retryBaseMs: 0,
    });

    const out = await client.createTokenPayload({ name: "Retry" });
    assert.equal(out.createArg, "0xaaaa");
    assert.equal(counters.create, 2);
  } finally {
    global.fetch = originalFetch;
  }
});
