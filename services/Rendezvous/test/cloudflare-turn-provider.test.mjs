import assert from "node:assert/strict";
import test from "node:test";
import {
  TurnProvisioningError,
  createCloudflareTurnProvider,
  normalizeCloudflareIceServers,
} from "../src/cloudflare-turn-provider.mjs";

// Security oracle: only strict Cloudflare-hosted ICE responses are accepted, bounded reads cannot
// exhaust memory, and every upstream failure becomes a non-secret-bearing public error.
const validPayload = () => ({
  iceServers: [
    { urls: ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"] },
    {
      urls: [
        "turn:turn.cloudflare.com:3478?transport=udp",
        "turns:turn.cloudflare.com:443?transport=tcp",
      ],
      username: "ephemeral-user",
      credential: "ephemeral-password",
    },
  ],
});

const response = (body, options = {}) =>
  new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status: options.status ?? 201,
    headers: {
      "content-type": options.contentType ?? "application/json; charset=utf-8",
      ...(options.headers ?? {}),
    },
  });

test("Cloudflare provider sends a server-side bearer request and normalizes password credentials", async () => {
  const calls = [];
  const provider = createCloudflareTurnProvider({
    keyId: "key_123",
    apiToken: "server-secret-token",
    ttlSeconds: 600,
    timeoutMs: 1_000,
    fetchImpl: async (...values) => {
      calls.push(values);
      return response(validPayload());
    },
  });

  const iceServers = await provider();
  assert.deepEqual(iceServers, [
    { urls: ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"] },
    {
      urls: [
        "turn:turn.cloudflare.com:3478?transport=udp",
        "turns:turn.cloudflare.com:443?transport=tcp",
      ],
      username: "ephemeral-user",
      credential: "ephemeral-password",
      credentialType: "password",
    },
  ]);
  assert.equal(calls.length, 1);
  const [requestUrl, request] = calls[0];
  assert.equal(
    requestUrl,
    "https://rtc.live.cloudflare.com/v1/turn/keys/key_123/credentials/generate-ice-servers",
  );
  assert.equal(request.method, "POST");
  assert.equal(request.headers.authorization, "Bearer server-secret-token");
  assert.deepEqual(JSON.parse(request.body), { ttl: 600 });
  assert.equal(request.signal.aborted, false);
  assert.ok(Object.isFrozen(iceServers));
  assert.ok(Object.isFrozen(iceServers[1].urls));
});

test("normalization accepts a single TURN URL and supplies credentialType=password", () => {
  assert.deepEqual(
    normalizeCloudflareIceServers({
      iceServers: [
        {
          urls: "turn:turn.cloudflare.com:3478?transport=udp",
          username: "u",
          credential: "p",
          credentialType: "password",
        },
      ],
    }),
    [
      {
        urls: ["turn:turn.cloudflare.com:3478?transport=udp"],
        username: "u",
        credential: "p",
        credentialType: "password",
      },
    ],
  );
});

test("provider aborts a hung credential request within the configured bound", async () => {
  let observedSignal;
  const provider = createCloudflareTurnProvider({
    keyId: "key",
    apiToken: "token",
    ttlSeconds: 60,
    timeoutMs: 20,
    fetchImpl: async (_url, { signal }) => {
      observedSignal = signal;
      return new Promise((_resolve, reject) => {
        signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      });
    },
  });

  await assert.rejects(provider(), TurnProvisioningError);
  assert.equal(observedSignal.aborted, true);
});

test("provider deadline does not depend on the injected fetch honoring AbortSignal", async () => {
  const provider = createCloudflareTurnProvider({
    keyId: "key",
    apiToken: "token",
    ttlSeconds: 60,
    timeoutMs: 20,
    fetchImpl: async () => new Promise(() => {}),
  });
  const startedAt = Date.now();
  await assert.rejects(provider(), TurnProvisioningError);
  assert.ok(Date.now() - startedAt < 500);
});

test("provider maps HTTP, content-type, JSON, and oversized response failures to a fixed safe error", async () => {
  const cases = [
    response({ error: "unauthorized-and-sensitive" }, { status: 401 }),
    response(validPayload(), { contentType: "text/plain" }),
    response("not-json"),
    response(JSON.stringify(validPayload()), { headers: { "content-length": "65537" } }),
    response("x".repeat(65_537)),
  ];

  for (const failedResponse of cases) {
    const provider = createCloudflareTurnProvider({
      keyId: "key",
      apiToken: "token",
      ttlSeconds: 600,
      timeoutMs: 1_000,
      fetchImpl: async () => failedResponse,
    });
    await assert.rejects(provider(), (error) => {
      assert.equal(error.name, "TurnProvisioningError");
      assert.equal(error.message, "TURN credentials are temporarily unavailable");
      assert.ok(!JSON.stringify(error).includes("unauthorized-and-sensitive"));
      return true;
    });
  }
});

test("normalization rejects malformed or unsafe ICE responses", () => {
  const malformed = [
    undefined,
    {},
    { iceServers: [] },
    { iceServers: [], extra: true },
    { iceServers: [{ urls: [] }] },
    { iceServers: [{ urls: ["https://turn.example.com"] }] },
    {
      iceServers: [
        {
          urls: ["turn:turn.attacker.example:3478?transport=udp"],
          username: "u",
          credential: "p",
        },
      ],
    },
    { iceServers: [{ urls: ["turn:"] }] },
    { iceServers: [{ urls: ["turn:turn.example.com/path"], username: "u", credential: "p" }] },
    {
      iceServers: [
        {
          urls: ["turn:turn.example.com?transport=udp&unexpected=true"],
          username: "u",
          credential: "p",
        },
      ],
    },
    { iceServers: [{ urls: ["stun:stun.example.com?transport=udp"] }] },
    { iceServers: [{ urls: ["turn:user@turn.example.com"], username: "u", credential: "p" }] },
    {
      iceServers: [
        {
          urls: ["stun:stun.example.com", "turn:turn.example.com"],
          username: "u",
          credential: "p",
        },
      ],
    },
    { iceServers: [{ urls: ["turn:turn.example.com"], username: "", credential: "p" }] },
    { iceServers: [{ urls: ["turn:turn.example.com"], username: "u", credential: "" }] },
    {
      iceServers: [
        {
          urls: ["turn:turn.example.com"],
          username: "u",
          credential: "p",
          credentialType: "token",
        },
      ],
    },
    { iceServers: [{ urls: ["stun:stun.example.com"], username: "unexpected" }] },
    { iceServers: [{ urls: ["stun:stun.example.com"], extra: true }] },
    { iceServers: [{ urls: ["stun:stun.example.com"] }] },
  ];

  for (const value of malformed) {
    assert.throws(() => normalizeCloudflareIceServers(value), TurnProvisioningError);
  }
});

test("provider rejects unsafe construction parameters without reflecting secrets", () => {
  for (const values of [
    { keyId: "bad/key", apiToken: "token", ttlSeconds: 600, timeoutMs: 1_000 },
    { keyId: "key", apiToken: "", ttlSeconds: 600, timeoutMs: 1_000 },
    { keyId: "key", apiToken: "secret\nheader", ttlSeconds: 600, timeoutMs: 1_000 },
    { keyId: "key", apiToken: "token", ttlSeconds: 59, timeoutMs: 1_000 },
    { keyId: "key", apiToken: "token", ttlSeconds: 172_801, timeoutMs: 1_000 },
    { keyId: "key", apiToken: "token", ttlSeconds: 600, timeoutMs: 0 },
  ]) {
    assert.throws(
      () => createCloudflareTurnProvider({ ...values, fetchImpl: async () => response(validPayload()) }),
      (error) => {
        assert.equal(error.message, "TURN credentials are temporarily unavailable");
        if (values.apiToken) assert.ok(!error.message.includes(values.apiToken));
        return true;
      },
    );
  }
});
