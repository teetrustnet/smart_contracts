const { Wallet } = require("ethers");

class FourMemeApiError extends Error {
  constructor(message, options = {}) {
    super(message);
    this.name = "FourMemeApiError";
    this.status = options.status ?? null;
    this.code = options.code ?? null;
    this.path = options.path ?? null;
    this.detail = options.detail ?? null;
  }
}

class FourMemeClient {
  constructor(options) {
    this.baseUrl = options.baseUrl.replace(/\/$/, "");
    this.networkCode = options.networkCode || "BSC";
    this.privateKey = options.privateKey;
    this.region = options.region || "WEB";
    this.langType = options.langType || "EN";
    this.walletName = options.walletName || "BackendService";
    this.verifyType = "LOGIN";

    this.accessTokenTtlMs = options.accessTokenTtlMs ?? 50 * 60 * 1000;
    this.maxRetries = options.maxRetries ?? 3;
    this.retryBaseMs = options.retryBaseMs ?? 800;

    this.wallet = new Wallet(this.privateKey);
    this.accountAddress = this.wallet.address;

    this.cachedAccessToken = null;
    this.cachedAccessTokenExpiresAt = 0;
    this.loginPromise = null;
  }

  _sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  _backoffMs(attempt) {
    const jitter = Math.floor(Math.random() * 180);
    return this.retryBaseMs * 2 ** Math.max(0, attempt - 1) + jitter;
  }

  _retryAfterMs(response, attempt) {
    const retryAfterHeader = response?.headers?.get?.("retry-after");
    if (!retryAfterHeader) return this._backoffMs(attempt);

    const asNumber = Number(retryAfterHeader);
    if (Number.isFinite(asNumber) && asNumber >= 0) {
      return asNumber * 1000;
    }

    const asDate = Date.parse(retryAfterHeader);
    if (!Number.isNaN(asDate)) {
      return Math.max(0, asDate - Date.now());
    }

    return this._backoffMs(attempt);
  }

  _isAuthExpiredError(error) {
    if (!(error instanceof FourMemeApiError)) return false;
    const detail = `${error.detail || ""}`.toLowerCase();

    return (
      error.status === 401 ||
      detail.includes("token") ||
      detail.includes("unauthorized") ||
      detail.includes("expire") ||
      detail.includes("login")
    );
  }

  async _post(path, payload, headers = {}) {
    let attempt = 0;

    while (true) {
      try {
        const response = await fetch(`${this.baseUrl}${path}`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            ...headers,
          },
          body: JSON.stringify(payload),
        });

        const text = await response.text();
        let json;
        try {
          json = JSON.parse(text);
        } catch {
          json = null;
        }

        if (response.status === 429 || response.status >= 500) {
          if (attempt >= this.maxRetries) {
            throw new FourMemeApiError(`four.meme HTTP ${response.status} on ${path}`, {
              status: response.status,
              path,
              detail: text,
            });
          }

          attempt += 1;
          await this._sleep(this._retryAfterMs(response, attempt));
          continue;
        }

        if (!json) {
          throw new FourMemeApiError(`four.meme non-json response ${response.status} on ${path}`, {
            status: response.status,
            path,
            detail: text,
          });
        }

        if (!response.ok || json.code !== "0") {
          throw new FourMemeApiError(`four.meme API error on ${path}`, {
            status: response.status,
            code: json.code,
            path,
            detail: json?.message || json?.msg || JSON.stringify(json),
          });
        }

        return json.data;
      } catch (error) {
        if (error instanceof FourMemeApiError) {
          throw error;
        }

        if (attempt >= this.maxRetries) {
          throw new FourMemeApiError(`four.meme network error on ${path}: ${error.message}`, {
            path,
            detail: error.message,
          });
        }

        attempt += 1;
        await this._sleep(this._backoffMs(attempt));
      }
    }
  }

  async _loginAndGetAccessToken() {
    const nonce = await this._post("/v1/private/user/nonce/generate", {
      accountAddress: this.accountAddress,
      verifyType: this.verifyType,
      networkCode: this.networkCode,
    });

    const signatureMessage = `You are sign in Meme ${nonce}`;
    const signature = await this.wallet.signMessage(signatureMessage);

    const accessToken = await this._post("/v1/private/user/login/dex", {
      region: this.region,
      langType: this.langType,
      loginIp: "",
      inviteCode: "",
      verifyInfo: {
        address: this.accountAddress,
        networkCode: this.networkCode,
        signature,
        verifyType: this.verifyType,
      },
      walletName: this.walletName,
    });

    this.cachedAccessToken = accessToken;
    this.cachedAccessTokenExpiresAt = Date.now() + this.accessTokenTtlMs;

    return accessToken;
  }

  async _getAccessToken(forceRefresh = false) {
    const hasValidCache =
      !forceRefresh &&
      this.cachedAccessToken &&
      Date.now() < this.cachedAccessTokenExpiresAt;

    if (hasValidCache) {
      return this.cachedAccessToken;
    }

    if (!this.loginPromise) {
      this.loginPromise = this._loginAndGetAccessToken().finally(() => {
        this.loginPromise = null;
      });
    }

    return this.loginPromise;
  }

  async createTokenPayload(createTokenRequest) {
    let accessToken = await this._getAccessToken(false);

    let created;
    try {
      created = await this._post("/v1/private/token/create", createTokenRequest, {
        "meme-web-access": accessToken,
      });
    } catch (error) {
      if (!this._isAuthExpiredError(error)) {
        throw error;
      }

      accessToken = await this._getAccessToken(true);
      created = await this._post("/v1/private/token/create", createTokenRequest, {
        "meme-web-access": accessToken,
      });
    }

    if (!created?.createArg || !created?.signature) {
      throw new FourMemeApiError("four.meme token/create missing createArg or signature");
    }

    return {
      createArg: created.createArg,
      signature: created.signature,
      accountAddress: this.accountAddress,
    };
  }
}

module.exports = { FourMemeClient, FourMemeApiError };
