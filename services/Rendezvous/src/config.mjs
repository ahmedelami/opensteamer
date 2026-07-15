const integer = (env, name, fallback, { min = 1, max = Number.MAX_SAFE_INTEGER } = {}) => {
  const raw = env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer from ${min} through ${max}`);
  }
  return value;
};

const urls = (env, name, allowedSchemes) => {
  const values = (env[name] ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);

  for (const value of values) {
    const scheme = value.slice(0, value.indexOf(":"));
    if (!allowedSchemes.includes(scheme)) {
      throw new Error(`${name} contains an unsupported URL scheme`);
    }
    if (/\s/.test(value) || value.includes("@")) {
      throw new Error(`${name} must not contain whitespace or embedded credentials`);
    }
  }
  return Object.freeze(values);
};

export function loadConfig(env = process.env) {
  const stunUrls = urls(env, "STUN_URLS", ["stun", "stuns"]);
  const turnUrls = urls(env, "TURN_URLS", ["turn", "turns"]);
  const turnSharedSecret = env.TURN_SHARED_SECRET?.trim() || undefined;
  const cloudflareTurnKeyId = env.CLOUDFLARE_TURN_KEY_ID?.trim() || undefined;
  const cloudflareTurnApiToken = env.CLOUDFLARE_TURN_API_TOKEN?.trim() || undefined;
  if (turnUrls.length > 0 && !turnSharedSecret) {
    throw new Error("TURN_SHARED_SECRET is required when TURN_URLS is configured");
  }
  if (Boolean(cloudflareTurnKeyId) !== Boolean(cloudflareTurnApiToken)) {
    throw new Error(
      "CLOUDFLARE_TURN_KEY_ID and CLOUDFLARE_TURN_API_TOKEN must be configured together",
    );
  }
  if (cloudflareTurnKeyId && !/^[A-Za-z0-9_-]{1,128}$/.test(cloudflareTurnKeyId)) {
    throw new Error("CLOUDFLARE_TURN_KEY_ID has an invalid format");
  }
  if (
    cloudflareTurnApiToken &&
    (Buffer.byteLength(cloudflareTurnApiToken, "utf8") > 4_096 ||
      /\s|[\u0000-\u001f\u007f]/.test(cloudflareTurnApiToken))
  ) {
    throw new Error("CLOUDFLARE_TURN_API_TOKEN has an invalid format");
  }
  if (cloudflareTurnKeyId && (turnUrls.length > 0 || turnSharedSecret)) {
    throw new Error("Cloudflare managed TURN and coturn REST credentials are mutually exclusive");
  }

  return Object.freeze({
    host: env.HOST?.trim() || "127.0.0.1",
    port: integer(env, "PORT", 8788, { min: 0, max: 65_535 }),
    trustProxyHops: integer(env, "TRUST_PROXY_HOPS", 0, { min: 0, max: 10 }),
    invitationTtlMs: integer(env, "INVITATION_TTL_SECONDS", 300, { min: 1, max: 3_600 }) * 1_000,
    heartbeatIntervalMs: integer(env, "HEARTBEAT_INTERVAL_MS", 15_000, { min: 10, max: 60_000 }),
    peerTimeoutMs: integer(env, "PEER_TIMEOUT_MS", 45_000, { min: 20, max: 180_000 }),
    rateWindowMs: integer(env, "RATE_WINDOW_SECONDS", 60, { min: 1, max: 3_600 }) * 1_000,
    ipAttemptLimit: integer(env, "IP_ATTEMPT_LIMIT", 60, { min: 1, max: 10_000 }),
    channelAttemptLimit: integer(env, "CHANNEL_ATTEMPT_LIMIT", 20, { min: 1, max: 10_000 }),
    ipMessageLimit: integer(env, "IP_MESSAGE_LIMIT", 600, { min: 1, max: 100_000 }),
    channelMessageLimit: integer(env, "CHANNEL_MESSAGE_LIMIT", 300, { min: 1, max: 100_000 }),
    maxEnvelopeBytes: integer(env, "MAX_ENVELOPE_BYTES", 65_536, { min: 256, max: 262_144 }),
    maxMessageBytes: integer(env, "MAX_MESSAGE_BYTES", 90_000, { min: 512, max: 350_000 }),
    maxSequence: integer(env, "MAX_SEQUENCE", 2_147_483_647, { min: 1, max: Number.MAX_SAFE_INTEGER }),
    stunUrls,
    turnUrls,
    turnSharedSecret,
    cloudflareTurnKeyId,
    cloudflareTurnApiToken,
    turnCredentialTtlSeconds: integer(env, "TURN_CREDENTIAL_TTL_SECONDS", 600, {
      min: 60,
      max: 86_400,
    }),
    cloudflareTurnFetchTimeoutMs: integer(env, "CLOUDFLARE_TURN_FETCH_TIMEOUT_MS", 5_000, {
      min: 100,
      max: 30_000,
    }),
  });
}
