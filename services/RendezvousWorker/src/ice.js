// ICE provisioning runs inside the Worker so TURN API credentials never reach either media peer.
// Every upstream value is treated as untrusted and normalized before it enters a ready message.
const TURN_ENDPOINT = "https://rtc.live.cloudflare.com/v1/turn/keys";
// Cloudflare's port 53 is only an alternate STUN endpoint and is blocked on some
// networks. Advertising it alongside the reachable primary endpoint causes native
// WebRTC to emit a candidate-gathering failure even after a direct route succeeds.
const DEFAULT_STUN_URLS = "stun:stun.cloudflare.com:3478";
const MAX_RESPONSE_BYTES = 65_536;
const MAX_ICE_SERVERS = 16;
const MAX_URLS_PER_SERVER = 8;
const MAX_ICE_URL_BYTES = 2_048;
const MAX_CREDENTIAL_BYTES = 1_024;
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });

const isRecord = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value, expected) => {
  if (!isRecord(value)) return false;
  const keys = Object.keys(value).sort();
  return keys.length === expected.length && keys.every((key, index) => key === expected[index]);
};
const utf8Length = (value) => textEncoder.encode(value).byteLength;
const validOpaque = (value) =>
  typeof value === "string" &&
  value.length > 0 &&
  utf8Length(value) <= MAX_CREDENTIAL_BYTES &&
  !/\s|[\u0000-\u001f\u007f]/.test(value);

/** Stable, intentionally non-diagnostic error for all TURN provisioning failures. */
export class TurnProvisioningError extends Error {
  constructor() {
    super("TURN credentials are temporarily unavailable");
    this.name = "TurnProvisioningError";
  }
}

const parseInteger = (value, fallback, { minimum, maximum }) => {
  if (value === undefined || value === "") return fallback;
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw new TurnProvisioningError();
  }
  return number;
};

const cloudflareIceFamily = (candidate) => {
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
  const expectedHost = family === "turn" ? "turn.cloudflare.com" : "stun.cloudflare.com";
  if (
    parsed.hostname !== expectedHost ||
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

const normalizeUrls = (
  value,
  allowedFamilies = new Set(["stun", "turn"]),
  requireCloudflareHosts = false,
) => {
  const candidates = typeof value === "string" ? [value] : value;
  if (
    !Array.isArray(candidates) ||
    candidates.length === 0 ||
    candidates.length > MAX_URLS_PER_SERVER
  ) {
    throw new TurnProvisioningError();
  }

  let family;
  const urls = [];
  for (const candidate of candidates) {
    if (
      typeof candidate !== "string" ||
      candidate.length === 0 ||
      utf8Length(candidate) > MAX_ICE_URL_BYTES ||
      /\s|@/.test(candidate)
    ) {
      throw new TurnProvisioningError();
    }
    const match = /^(stun|stuns|turn|turns):/i.exec(candidate);
    if (!match) throw new TurnProvisioningError();
    const nextFamily = requireCloudflareHosts
      ? cloudflareIceFamily(candidate)
      : (match[1].toLowerCase().startsWith("turn") ? "turn" : "stun");
    if (!allowedFamilies.has(nextFamily) || (family && family !== nextFamily)) {
      throw new TurnProvisioningError();
    }
    family = nextFamily;
    if (!urls.includes(candidate)) urls.push(candidate);
  }
  return { family, urls };
};

/** Returns the validated public STUN configuration advertised when managed TURN is absent. */
export function configuredStunServers(env) {
  const raw = typeof env.STUN_URLS === "string" ? env.STUN_URLS : DEFAULT_STUN_URLS;
  const candidates = raw
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  if (candidates.length === 0) return [];
  const { urls } = normalizeUrls(candidates, new Set(["stun"]));
  return [{ urls }];
}

/**
 * Validates Cloudflare's managed TURN response using exact schemas and an ICE host allow-list.
 *
 * @param {unknown} payload Untrusted upstream JSON.
 * @returns {Array<object>} Sanitized WebRTC ICE server descriptors.
 */
export function normalizeCloudflareIceServers(payload) {
  if (
    !exactKeys(payload, ["iceServers"]) ||
    !Array.isArray(payload.iceServers) ||
    payload.iceServers.length === 0 ||
    payload.iceServers.length > MAX_ICE_SERVERS
  ) {
    throw new TurnProvisioningError();
  }

  let hasTurn = false;
  const normalized = payload.iceServers.map((server) => {
    if (!isRecord(server)) throw new TurnProvisioningError();
    const { family, urls } = normalizeUrls(
      server.urls,
      new Set(["stun", "turn"]),
      true,
    );
    if (family === "stun") {
      if (!exactKeys(server, ["urls"])) throw new TurnProvisioningError();
      return { urls };
    }

    const keysWithoutType = ["credential", "urls", "username"];
    const keysWithType = ["credential", "credentialType", "urls", "username"];
    if (!exactKeys(server, keysWithoutType) && !exactKeys(server, keysWithType)) {
      throw new TurnProvisioningError();
    }
    if (
      !validOpaque(server.username) ||
      !validOpaque(server.credential) ||
      (Object.hasOwn(server, "credentialType") && server.credentialType !== "password")
    ) {
      throw new TurnProvisioningError();
    }
    hasTurn = true;
    return {
      urls,
      username: server.username,
      credential: server.credential,
      credentialType: "password",
    };
  });

  if (!hasTurn) throw new TurnProvisioningError();
  return normalized;
}

async function readBoundedJSON(response) {
  const contentType = response.headers.get("content-type") ?? "";
  if (!/^application\/json(?:\s*;|$)/i.test(contentType)) throw new TurnProvisioningError();
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null) {
    if (!/^\d+$/.test(contentLength) || Number(contentLength) > MAX_RESPONSE_BYTES) {
      throw new TurnProvisioningError();
    }
  }
  if (!response.body) throw new TurnProvisioningError();

  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_RESPONSE_BYTES) throw new TurnProvisioningError();
      chunks.push(value);
    }
  } catch {
    await reader.cancel().catch(() => {});
    throw new TurnProvisioningError();
  }

  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(textDecoder.decode(body));
  } catch {
    throw new TurnProvisioningError();
  }
}

/**
 * Fetches bounded, short-lived TURN credentials without surfacing request metadata on failure.
 *
 * @param {Record<string, string | undefined>} env Worker bindings and configuration.
 * @param {typeof fetch} [fetchImpl] Injectable fetch implementation for unit tests.
 */
export async function fetchCloudflareIceServers(env, fetchImpl = fetch) {
  const keyId = typeof env.CLOUDFLARE_TURN_KEY_ID === "string"
    ? env.CLOUDFLARE_TURN_KEY_ID.trim()
    : "";
  const apiToken = typeof env.CLOUDFLARE_TURN_API_TOKEN === "string"
    ? env.CLOUDFLARE_TURN_API_TOKEN.trim()
    : "";
  if (!keyId || !apiToken || !/^[A-Za-z0-9_-]{1,128}$/.test(keyId) || !validOpaque(apiToken)) {
    throw new TurnProvisioningError();
  }

  const ttl = parseInteger(env.TURN_CREDENTIAL_TTL_SECONDS, 600, {
    minimum: 60,
    maximum: 172_800,
  });
  const timeoutMs = parseInteger(env.TURN_FETCH_TIMEOUT_MS, 5_000, {
    minimum: 1,
    maximum: 30_000,
  });
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(
      `${TURN_ENDPOINT}/${encodeURIComponent(keyId)}/credentials/generate-ice-servers`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ ttl }),
        signal: controller.signal,
      },
    );
    if (response.status !== 201) throw new TurnProvisioningError();
    return normalizeCloudflareIceServers(await readBoundedJSON(response));
  } catch {
    // Fetch implementations can include request headers or URLs in thrown errors. Collapse every
    // failure to a fixed message so a bearer token cannot leak through logs or client responses.
    throw new TurnProvisioningError();
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Produces the ICE list for one authenticated join, preferring managed TURN when configured.
 * A half-configured key/token pair fails closed instead of silently degrading to STUN-only.
 */
export async function iceServersForJoin(env, fetchImpl = fetch) {
  const hasKey = typeof env.CLOUDFLARE_TURN_KEY_ID === "string" &&
    env.CLOUDFLARE_TURN_KEY_ID.trim().length > 0;
  const hasToken = typeof env.CLOUDFLARE_TURN_API_TOKEN === "string" &&
    env.CLOUDFLARE_TURN_API_TOKEN.trim().length > 0;
  if (!hasKey && !hasToken) return configuredStunServers(env);
  if (!hasKey || !hasToken) throw new TurnProvisioningError();

  const provisioned = await fetchCloudflareIceServers(env, fetchImpl);
  const hasStun = provisioned.some((server) => /^stuns?:/i.test(server.urls[0]));
  const combined = hasStun ? provisioned : [...configuredStunServers(env), ...provisioned];
  if (combined.length > MAX_ICE_SERVERS) throw new TurnProvisioningError();
  return combined;
}
