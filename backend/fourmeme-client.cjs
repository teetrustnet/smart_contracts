const { Wallet } = require("ethers");

class FourMemeClient {
  constructor(options) {
    this.baseUrl = options.baseUrl.replace(/\/$/, "");
    this.networkCode = options.networkCode || "BSC";
    this.privateKey = options.privateKey;
    this.region = options.region || "WEB";
    this.langType = options.langType || "EN";
    this.walletName = options.walletName || "BackendService";
    this.verifyType = "LOGIN";
  }

  async _post(path, payload, headers = {}) {
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
      throw new Error(`four.meme non-json response ${response.status}: ${text}`);
    }

    if (!response.ok || json.code !== "0") {
      const detail = json?.message || json?.msg || JSON.stringify(json);
      throw new Error(`four.meme API error ${path}: ${detail}`);
    }

    return json.data;
  }

  async createTokenPayload(createTokenRequest) {
    const wallet = new Wallet(this.privateKey);
    const accountAddress = wallet.address;

    const nonce = await this._post("/v1/private/user/nonce/generate", {
      accountAddress,
      verifyType: this.verifyType,
      networkCode: this.networkCode,
    });

    const signatureMessage = `You are sign in Meme ${nonce}`;
    const signature = await wallet.signMessage(signatureMessage);

    const accessToken = await this._post("/v1/private/user/login/dex", {
      region: this.region,
      langType: this.langType,
      loginIp: "",
      inviteCode: "",
      verifyInfo: {
        address: accountAddress,
        networkCode: this.networkCode,
        signature,
        verifyType: this.verifyType,
      },
      walletName: this.walletName,
    });

    const created = await this._post("/v1/private/token/create", createTokenRequest, {
      "meme-web-access": accessToken,
    });

    if (!created?.createArg || !created?.signature) {
      throw new Error("four.meme token/create missing createArg or signature");
    }

    return {
      createArg: created.createArg,
      signature: created.signature,
      accountAddress,
    };
  }
}

module.exports = { FourMemeClient };
