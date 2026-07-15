const CLOUDFLARE_TURN_CREDENTIAL_ENDPOINT =
  "https://rtc.live.cloudflare.com/v1/turn/keys";
const MAX_RESPONSE_BYTES = 65_536;
const MAX_ICE_SERVERS = 8;
const MAX_URLS_PER_SERVER = 16;
const MAX_ICE_URL_BYTES = 2_048;
const MAX_CREDENTIAL_BYTES = 4_096;

const isRecord = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);

const hasOnlyKeys = (value, allowed) =>
  Object.keys(value).every((key) => allowed.has(key));

const utf8Length = (value) => Buffer.byteLength(value, "utf8");

const validOpaqueString = (value) =>
  typeof value === "string" &&
  value.length > 0 &&
  utf8Length(value) <= MAX_CREDENTIAL_BYTES &&
  !/\s|[\u0000-\u001f\u007f]/.test(value);

const iceUrlFamily = (candidate) => {
  const match = /^(stun|stuns|turn|turns):([^?#]+)(\?[^#]+)?$/.exec(candidate);
  if (!match) throw new TurnProvisioningError();
  const [, scheme, authority, query] = match;
  const family = scheme.startsWith("turn") ? "turn" : "stun";
  if ((family === "stun" && query) || (query && !/^\?transport=(?:udp|tcp)$/.test(query))) {
    throw new TurnProvisioningError();
  }
  let parsed;
  try {
    parsed = new URL(`https://${authority}`);
  } catch {
    throw new TurnProvisioningError();
  }
  if (
    !parsed.hostname ||
    parsed.hostname !== (family === "turn" ? "turn.cloudflare.com" : "stun.cloudflare.com") ||
    parsed.username ||
    parsed.password ||
    parsed.pathname !== "/" ||
    parsed.search ||
    parsed.hash
  ) {
    throw new TurnProvisioningError();
  }
  return family;
};

const normalizeUrls = (value) => {
  const values = typeof value === "string" ? [value] : value;
  if (!Array.isArray(values) || values.length === 0 || values.length > MAX_URLS_PER_SERVER) {
    throw new TurnProvisioningError();
  }

  const urls = [];
  let family;
  for (const candidate of values) {
    if (
      typeof candidate !== "string" ||
      candidate.length === 0 ||
      utf8Length(candidate) > MAX_ICE_URL_BYTES ||
      /\s|@/.test(candidate)
    ) {
      throw new TurnProvisioningError();
    }
    const nextFamily = iceUrlFamily(candidate);
    if (family && family !== nextFamily) throw new TurnProvisioningError();
    family = nextFamily;
    if (!urls.includes(candidate)) urls.push(candidate);
  }
  return { family, urls };
};

export class TurnProvisioningError extends Error {
  constructor() {
    super("TURN credentials are temporarily unavailable");
    this.name = "TurnProvisioningError";
  }
}

export function normalizeCloudflareIceServers(payload) {
  if (
    !isRecord(payload) ||
    !hasOnlyKeys(payload, new Set(["iceServers"])) ||
    !Array.isArray(payload.iceServers) ||
    payload.iceServers.length === 0 ||
    payload.iceServers.length > MAX_ICE_SERVERS
  ) {
    throw new TurnProvisioningError();
  }

  let hasTurnServer = false;
  const normalized = payload.iceServers.map((server) => {
    if (
      !isRecord(server) ||
      !hasOnlyKeys(server, new Set(["urls", "username", "credential", "credentialType"]))
    ) {
      throw new TurnProvisioningError();
    }
    const { family, urls } = normalizeUrls(server.urls);
    if (family === "stun") {
      if (
        Object.hasOwn(server, "username") ||
        Object.hasOwn(server, "credential") ||
        Object.hasOwn(server, "credentialType")
      ) {
        throw new TurnProvisioningError();
      }
      return Object.freeze({ urls: Object.freeze(urls) });
    }

    if (
      !validOpaqueString(server.username) ||
      !validOpaqueString(server.credential) ||
      (Object.hasOwn(server, "credentialType") && server.credentialType !== "password")
    ) {
      throw new TurnProvisioningError();
    }
    hasTurnServer = true;
    return Object.freeze({
      urls: Object.freeze(urls),
      username: server.username,
      credential: server.credential,
      credentialType: "password",
    });
  });

  if (!hasTurnServer) throw new TurnProvisioningError();
  return Object.freeze(normalized);
}

const readBody = async (response) => {
  const reader = response.body?.getReader?.();
  if (!reader) {
    const body = await response.text();
    if (utf8Length(body) > MAX_RESPONSE_BYTES) throw new TurnProvisioningError();
    return body;
  }

  const chunks = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array)) throw new TurnProvisioningError();
      totalBytes += value.byteLength;
      if (totalBytes > MAX_RESPONSE_BYTES) {
        void reader.cancel().catch(() => {});
        throw new TurnProvisioningError();
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock?.();
  }
  return Buffer.concat(chunks, totalBytes).toString("utf8");
};

const readJson = async (response) => {
  const contentType = response.headers?.get?.("content-type") ?? "";
  if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
    throw new TurnProvisioningError();
  }
  const contentLength = Number(response.headers?.get?.("content-length"));
  if (Number.isFinite(contentLength) && contentLength > MAX_RESPONSE_BYTES) {
    throw new TurnProvisioningError();
  }
  const body = await readBody(response);
  try {
    return JSON.parse(body);
  } catch {
    throw new TurnProvisioningError();
  }
};

export function createCloudflareTurnProvider({
  keyId,
  apiToken,
  ttlSeconds,
  timeoutMs,
  fetchImpl = globalThis.fetch,
}) {
  if (
    typeof keyId !== "string" ||
    !/^[A-Za-z0-9_-]{1,128}$/.test(keyId) ||
    !validOpaqueString(apiToken) ||
    !Number.isSafeInteger(ttlSeconds) ||
    ttlSeconds < 60 ||
    ttlSeconds > 172_800 ||
    !Number.isSafeInteger(timeoutMs) ||
    timeoutMs < 1 ||
    timeoutMs > 30_000 ||
    typeof fetchImpl !== "function"
  ) {
    throw new TurnProvisioningError();
  }

  const endpoint = `${CLOUDFLARE_TURN_CREDENTIAL_ENDPOINT}/${encodeURIComponent(
    keyId,
  )}/credentials/generate-ice-servers`;

  return async () => {
    const controller = new AbortController();
    let timeout;
    const deadline = new Promise((_resolve, reject) => {
      timeout = setTimeout(() => {
        controller.abort();
        reject(new TurnProvisioningError());
      }, timeoutMs);
    });
    try {
      const request = (async () => {
        const response = await fetchImpl(endpoint, {
          method: "POST",
          headers: Object.freeze({
            authorization: `Bearer ${apiToken}`,
            "content-type": "application/json",
          }),
          body: JSON.stringify({ ttl: ttlSeconds }),
          signal: controller.signal,
        });
        if (!response || response.status !== 201) throw new TurnProvisioningError();
        return normalizeCloudflareIceServers(await readJson(response));
      })();
      return await Promise.race([request, deadline]);
    } catch {
      // Deliberately discard fetch errors: they can contain request metadata. Callers get a fixed,
      // non-secret-bearing error and must never log the key ID or bearer token.
      throw new TurnProvisioningError();
    } finally {
      clearTimeout(timeout);
    }
  };
}
