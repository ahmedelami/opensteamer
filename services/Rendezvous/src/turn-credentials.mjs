import { createHmac, randomBytes as systemRandomBytes } from "node:crypto";

/**
 * Generates a coturn REST username/password pair with an opaque subject and bounded lifetime.
 * The shared secret is used only as the HMAC key and is never included in the result.
 */
export function createTurnCredential({ sharedSecret, ttlSeconds, now = Date.now(), randomBytes = systemRandomBytes }) {
  if (!sharedSecret) throw new Error("A TURN shared secret is required");
  const expiresAtSeconds = Math.floor(now / 1_000) + ttlSeconds;
  const opaqueSubject = randomBytes(12).toString("base64url");
  const username = `${expiresAtSeconds}:${opaqueSubject}`;
  const credential = createHmac("sha1", sharedSecret).update(username).digest("base64");
  return Object.freeze({ username, credential, expiresAt: expiresAtSeconds * 1_000 });
}

/** Builds the WebRTC ICE list, minting a fresh coturn credential when TURN is configured. */
export function buildIceServers(config, options = {}) {
  const iceServers = [];
  if (config.stunUrls.length > 0) {
    iceServers.push({ urls: [...config.stunUrls] });
  }
  if (config.turnUrls.length > 0) {
    const credential = createTurnCredential({
      sharedSecret: config.turnSharedSecret,
      ttlSeconds: config.turnCredentialTtlSeconds,
      now: options.now,
      randomBytes: options.randomBytes,
    });
    iceServers.push({
      urls: [...config.turnUrls],
      username: credential.username,
      credential: credential.credential,
      credentialType: "password",
    });
  }
  return iceServers;
}
