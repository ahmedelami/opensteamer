import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { loadConfig } from "../src/config.mjs";
import { decodeAdmissionProof, validateJoin, validateSignal } from "../src/protocol.mjs";
import { FixedWindowLimiter } from "../src/rate-limiter.mjs";
import { buildIceServers, createTurnCredential } from "../src/turn-credentials.mjs";

test("configuration validates TURN authentication and URL schemes", () => {
  assert.throws(
    () => loadConfig({ TURN_URLS: "turn:turn.example.com:3478" }),
    /TURN_SHARED_SECRET is required/,
  );
  assert.throws(() => loadConfig({ STUN_URLS: "https://example.com" }), /unsupported URL scheme/);
  assert.throws(
    () => loadConfig({ TURN_URLS: "turn:user@turn.example.com", TURN_SHARED_SECRET: "secret" }),
    /embedded credentials/,
  );
  assert.throws(
    () => loadConfig({ CLOUDFLARE_TURN_KEY_ID: "key-without-token" }),
    /must be configured together/,
  );
  assert.throws(
    () => loadConfig({ CLOUDFLARE_TURN_API_TOKEN: "token-without-key" }),
    /must be configured together/,
  );
  assert.throws(
    () =>
      loadConfig({
        CLOUDFLARE_TURN_KEY_ID: "managed-key",
        CLOUDFLARE_TURN_API_TOKEN: "managed-token",
        TURN_URLS: "turn:turn.example.com:3478",
        TURN_SHARED_SECRET: "coturn-secret",
      }),
    /mutually exclusive/,
  );
  assert.throws(
    () =>
      loadConfig({
        CLOUDFLARE_TURN_KEY_ID: "bad/key",
        CLOUDFLARE_TURN_API_TOKEN: "managed-token",
      }),
    /KEY_ID has an invalid format/,
  );

  const managed = loadConfig({
    CLOUDFLARE_TURN_KEY_ID: "managed-key",
    CLOUDFLARE_TURN_API_TOKEN: "managed-token",
    TURN_CREDENTIAL_TTL_SECONDS: "300",
    CLOUDFLARE_TURN_FETCH_TIMEOUT_MS: "2500",
  });
  assert.equal(managed.cloudflareTurnKeyId, "managed-key");
  assert.equal(managed.cloudflareTurnApiToken, "managed-token");
  assert.equal(managed.turnCredentialTtlSeconds, 300);
  assert.equal(managed.cloudflareTurnFetchTimeoutMs, 2_500);
});

test("coturn REST credentials use expiring HMAC-SHA1 passwords", () => {
  const secret = "test-shared-secret";
  const credential = createTurnCredential({
    sharedSecret: secret,
    ttlSeconds: 600,
    now: 1_700_000_000_000,
    randomBytes: () => Buffer.alloc(12, 7),
  });
  assert.match(credential.username, /^1700000600:/);
  assert.equal(
    credential.credential,
    createHmac("sha1", secret).update(credential.username).digest("base64"),
  );
  assert.equal(credential.expiresAt, 1_700_000_600_000);

  const config = loadConfig({
    STUN_URLS: "stun:stun.example.com:3478",
    TURN_URLS: "turn:turn.example.com:3478,turns:turn.example.com:5349",
    TURN_SHARED_SECRET: secret,
  });
  const iceServers = buildIceServers(config, {
    now: 1_700_000_000_000,
    randomBytes: () => Buffer.alloc(12, 8),
  });
  assert.deepEqual(iceServers[0], { urls: ["stun:stun.example.com:3478"] });
  assert.deepEqual(iceServers[1].urls, ["turn:turn.example.com:3478", "turns:turn.example.com:5349"]);
  assert.equal(iceServers[1].credentialType, "password");
  assert.ok(!JSON.stringify(iceServers).includes(secret));
});

test("join and sealed signal validation reject weak channels, replay, extras, and oversized payloads", () => {
  const channel = "a".repeat(22);
  assert.equal(validateJoin(channel, "host"), undefined);
  assert.equal(validateJoin("short", "host"), "invalid_channel");
  assert.equal(validateJoin([channel], "host"), "invalid_channel");
  assert.equal(validateJoin(channel, "admin"), "invalid_role");

  const options = { expectedSequence: 0, maxSequence: 100, maxEnvelopeBytes: 8 };
  assert.deepEqual(validateSignal('{"type":"signal","seq":0,"envelope":"YWJj"}', options).value, {
    type: "signal",
    seq: 0,
    envelope: "YWJj",
  });
  assert.equal(
    validateSignal('{"type":"signal","seq":1,"envelope":"YWJj"}', options).error,
    "unexpected_sequence",
  );
  assert.equal(
    validateSignal('{"type":"signal","seq":0,"envelope":"YWJj","secret":"no"}', options).error,
    "invalid_message",
  );
  assert.equal(
    validateSignal(`{"type":"signal","seq":0,"envelope":"${Buffer.alloc(9).toString("base64url")}"}`, options)
      .error,
    "envelope_too_large",
  );
});

test("admission proof validation accepts only canonical 32-byte Base64URL values", () => {
  const proof = Buffer.alloc(32, 7).toString("base64url");
  assert.deepEqual(decodeAdmissionProof(proof), Buffer.alloc(32, 7));
  assert.equal(decodeAdmissionProof(undefined), undefined);
  assert.equal(decodeAdmissionProof([proof]), undefined);
  assert.equal(decodeAdmissionProof(`${proof}=`), undefined);
  assert.equal(decodeAdmissionProof(`${proof.slice(0, -1)}x`), undefined);
});

test("fixed-window rate limiter resets and prunes deterministically", () => {
  const limiter = new FixedWindowLimiter({ limit: 2, windowMs: 100 });
  assert.equal(limiter.take("key", 0).allowed, true);
  assert.equal(limiter.take("key", 1).allowed, true);
  assert.equal(limiter.take("key", 2).allowed, false);
  assert.equal(limiter.take("key", 100).allowed, true);
  limiter.prune(200);
  assert.equal(limiter.take("key", 200).remaining, 1);
});
