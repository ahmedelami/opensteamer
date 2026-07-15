import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import WebSocket from "ws";
import { loadConfig } from "../src/config.mjs";
import { createRendezvousServer } from "../src/server.mjs";

class TestClient {
  constructor(socket) {
    this.socket = socket;
    this.messages = [];
    this.waiters = [];
    socket.on("message", (data) => {
      const message = JSON.parse(data.toString("utf8"));
      const waiterIndex = this.waiters.findIndex((waiter) => waiter.predicate(message));
      if (waiterIndex >= 0) {
        const [waiter] = this.waiters.splice(waiterIndex, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(message);
      } else {
        this.messages.push(message);
      }
    });
  }

  next(predicate = () => true, timeoutMs = 1_000) {
    const index = this.messages.findIndex(predicate);
    if (index >= 0) return Promise.resolve(this.messages.splice(index, 1)[0]);
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve, timer: undefined };
      waiter.timer = setTimeout(() => {
        const waiterIndex = this.waiters.indexOf(waiter);
        if (waiterIndex >= 0) this.waiters.splice(waiterIndex, 1);
        reject(new Error("Timed out waiting for WebSocket message"));
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  closed(timeoutMs = 1_000) {
    if (this.socket.readyState === WebSocket.CLOSED) {
      return Promise.resolve({ code: this.socket._closeCode, reason: this.socket._closeMessage?.toString() ?? "" });
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("Timed out waiting for WebSocket close")), timeoutMs);
      this.socket.once("close", (code, reason) => {
        clearTimeout(timer);
        resolve({ code, reason: reason.toString("utf8") });
      });
    });
  }
}

const defaultAdmissionProof = Buffer.alloc(32, 0xa5).toString("base64url");
const upgradeOptions = (join, admissionProof) => {
  const headers = {
    "X-AudioStreamer-Channel": join.channel,
    "X-AudioStreamer-Role": join.role,
  };
  if (admissionProof !== null) headers["X-AudioStreamer-Admission"] = admissionProof;
  return { headers };
};

const openClient = (
  url,
  { disablePong = false, admissionProof = defaultAdmissionProof } = {},
) =>
  new Promise((resolve, reject) => {
    const socket = new WebSocket(url.endpoint, upgradeOptions(url, admissionProof));
    if (disablePong) socket.pong = () => {};
    const client = new TestClient(socket);
    socket.once("open", () => resolve(client));
    socket.once("error", reject);
  });

const rejectedStatus = (url, { admissionProof = defaultAdmissionProof } = {}) =>
  new Promise((resolve, reject) => {
    const socket = new WebSocket(url.endpoint, upgradeOptions(url, admissionProof));
    socket.once("unexpected-response", (_request, response) => {
      response.resume();
      resolve(response.statusCode);
    });
    socket.once("open", () => reject(new Error("Expected WebSocket upgrade to be rejected")));
    socket.once("error", (error) => {
      if (!String(error.message).includes("Unexpected server response")) reject(error);
    });
  });

async function fixture(t, environment = {}, options = {}) {
  const logs = [];
  const config = loadConfig({
    HOST: "127.0.0.1",
    PORT: "0",
    STUN_URLS: "stun:stun.example.com:3478",
    IP_ATTEMPT_LIMIT: "100",
    CHANNEL_ATTEMPT_LIMIT: "100",
    IP_MESSAGE_LIMIT: "100",
    CHANNEL_MESSAGE_LIMIT: "100",
    ...environment,
  });
  const rendezvous = createRendezvousServer({
    config,
    logger: {
      info: (...values) => logs.push(values),
      error: (...values) => logs.push(values),
    },
    ...options,
  });
  const address = await rendezvous.start();
  t.after(() => rendezvous.stop());
  return { base: `ws://127.0.0.1:${address.port}`, httpBase: `http://127.0.0.1:${address.port}`, logs };
}

const url = (base, channel, role) => ({
  endpoint: `${base}/v1/rendezvous`,
  channel,
  role,
});

test("one host and consume-once viewer exchange unchanged sealed envelopes and ephemeral TURN credentials", async (t) => {
  const secret = "integration-only-turn-secret";
  const { base, httpBase, logs } = await fixture(t, {
    TURN_URLS: "turn:turn.example.com:3478?transport=udp,turns:turn.example.com:5349?transport=tcp",
    TURN_SHARED_SECRET: secret,
  });
  const channel = "A".repeat(22);
  const host = await openClient(url(base, channel, "host"));
  assert.equal((await host.next()).type, "waiting");
  const viewer = await openClient(url(base, channel, "viewer"));
  const [hostReady, viewerReady] = await Promise.all([
    host.next((message) => message.type === "ready"),
    viewer.next((message) => message.type === "ready"),
  ]);
  assert.equal(hostReady.role, "host");
  assert.equal(viewerReady.role, "viewer");
  for (const ready of [hostReady, viewerReady]) {
    const turn = ready.iceServers.find((server) => server.urls[0].startsWith("turn:"));
    assert.ok(turn);
    assert.equal(turn.credential, createHmac("sha1", secret).update(turn.username).digest("base64"));
    assert.ok(!JSON.stringify(ready).includes(secret));
  }

  const envelope = Buffer.from("sealed signaling ciphertext").toString("base64url");
  host.socket.send(JSON.stringify({ type: "signal", seq: 0, envelope }));
  assert.deepEqual(await viewer.next((message) => message.type === "signal"), {
    type: "signal",
    from: "host",
    seq: 0,
    envelope,
  });

  const health = await fetch(`${httpBase}/healthz`).then((response) => response.json());
  assert.deepEqual(health, { ok: true, pendingInvitations: 0, activeSessions: 1 });

  viewer.socket.close();
  await viewer.closed();
  assert.deepEqual(await host.next((message) => message.type === "peer-left"), {
    type: "peer-left",
    role: "viewer",
  });
  const replacement = await openClient(url(base, channel, "viewer"));
  assert.deepEqual(await replacement.next(), {
    type: "error",
    error: "role_already_claimed",
  });
  assert.equal((await replacement.closed()).code, 4409);

  host.socket.close();
  await host.closed();
  const replayedHost = await openClient(url(base, channel, "host"));
  assert.deepEqual(await replayedHost.next(), {
    type: "error",
    error: "role_already_claimed",
  });
  assert.equal((await replayedHost.closed()).code, 4409);
  assert.ok(!JSON.stringify(logs).includes(secret));
  assert.ok(!JSON.stringify(logs).includes(defaultAdmissionProof));
  assert.ok(!JSON.stringify(logs).includes(channel));
  assert.ok(!JSON.stringify(logs).includes(envelope));
});

test("async ICE provisioning is atomic and can return distinct credentials for each role", async (t) => {
  const calls = [];
  const { base } = await fixture(
    t,
    {},
    {
      iceServerProvider: async ({ role }) => {
        calls.push(role);
        await Promise.resolve();
        return [
          {
            urls: ["turn:turn.example.com:3478?transport=udp"],
            username: `${role}-user`,
            credential: `${role}-password`,
            credentialType: "password",
          },
        ];
      },
    },
  );
  const channel = "J".repeat(22);
  const host = await openClient(url(base, channel, "host"));
  await host.next((message) => message.type === "waiting");
  const viewer = await openClient(url(base, channel, "viewer"));
  const [hostReady, viewerReady] = await Promise.all([
    host.next((message) => message.type === "ready"),
    viewer.next((message) => message.type === "ready"),
  ]);

  assert.deepEqual(calls.sort(), ["host", "viewer"]);
  assert.equal(hostReady.iceServers[0].username, "host-user");
  assert.equal(viewerReady.iceServers[0].username, "viewer-user");
  host.socket.close();
  viewer.socket.close();
});

test("Cloudflare managed TURN config provisions short-lived credentials without exposing its secret", async (t) => {
  const apiToken = "cloudflare-server-side-secret";
  const keyId = "cloudflare-key-id";
  const requests = [];
  const { base, logs } = await fixture(
    t,
    {
      CLOUDFLARE_TURN_KEY_ID: keyId,
      CLOUDFLARE_TURN_API_TOKEN: apiToken,
      TURN_CREDENTIAL_TTL_SECONDS: "300",
    },
    {
      fetchImpl: async (requestUrl, request) => {
        requests.push({ requestUrl, request });
        const serial = requests.length;
        return new Response(
          JSON.stringify({
            iceServers: [
              { urls: ["stun:stun.cloudflare.com:3478"] },
              {
                urls: ["turn:turn.cloudflare.com:3478?transport=udp"],
                username: `managed-user-${serial}`,
                credential: `managed-password-${serial}`,
              },
            ],
          }),
          { status: 201, headers: { "content-type": "application/json" } },
        );
      },
    },
  );
  const channel = "L".repeat(22);
  const host = await openClient(url(base, channel, "host"));
  await host.next((message) => message.type === "waiting");
  const viewer = await openClient(url(base, channel, "viewer"));
  const readyMessages = await Promise.all([
    host.next((message) => message.type === "ready"),
    viewer.next((message) => message.type === "ready"),
  ]);

  assert.equal(requests.length, 2);
  for (const { requestUrl, request } of requests) {
    assert.ok(requestUrl.includes(`/keys/${keyId}/credentials/generate-ice-servers`));
    assert.equal(request.headers.authorization, `Bearer ${apiToken}`);
    assert.deepEqual(JSON.parse(request.body), { ttl: 300 });
  }
  const usernames = [];
  for (const ready of readyMessages) {
    const turn = ready.iceServers.find((server) => server.urls[0].startsWith("turn:"));
    assert.equal(turn.credentialType, "password");
    usernames.push(turn.username);
    assert.ok(!JSON.stringify(ready).includes(apiToken));
    assert.ok(!JSON.stringify(ready).includes(keyId));
  }
  assert.equal(new Set(usernames).size, 2);
  assert.ok(!JSON.stringify(logs).includes(apiToken));
  assert.ok(!JSON.stringify(logs).includes(keyId));
  host.socket.close();
  viewer.socket.close();
});

test("ICE provisioning failure sends no ready state and fails closed for both peers", async (t) => {
  const secret = "must-not-appear-in-logs";
  let call = 0;
  const { base, logs } = await fixture(
    t,
    {},
    {
      iceServerProvider: async () => {
        call += 1;
        if (call === 1) throw new Error(secret);
        return [{ urls: ["stun:stun.example.com:3478"] }];
      },
    },
  );
  const channel = "K".repeat(22);
  const host = await openClient(url(base, channel, "host"));
  await host.next((message) => message.type === "waiting");
  const viewer = await openClient(url(base, channel, "viewer"));
  const [hostError, viewerError] = await Promise.all([
    host.next((message) => message.type === "error"),
    viewer.next((message) => message.type === "error"),
  ]);

  assert.equal(hostError.error, "ice_server_unavailable");
  assert.equal(viewerError.error, "ice_server_unavailable");
  assert.equal((await host.closed()).code, 4503);
  assert.equal((await viewer.closed()).code, 4503);
  assert.ok(!host.messages.some((message) => message.type === "ready"));
  assert.ok(!viewer.messages.some((message) => message.type === "ready"));
  assert.ok(!JSON.stringify(logs).includes(secret));
});

test("admission proof is mandatory and a mismatch cannot consume an invitation", async (t) => {
  const { base } = await fixture(t);
  const channel = "J".repeat(22);
  const correctProof = Buffer.alloc(32, 0x11).toString("base64url");
  const wrongProof = Buffer.alloc(32, 0x22).toString("base64url");

  const queryJoin = url(base, channel, "host");
  queryJoin.endpoint += `?channel=${channel}&role=host`;
  assert.equal(await rejectedStatus(queryJoin, { admissionProof: correctProof }), 400);

  assert.equal(
    await rejectedStatus(url(base, channel, "host"), { admissionProof: null }),
    400,
  );
  assert.equal(
    await rejectedStatus(url(base, channel, "host"), { admissionProof: "not-a-proof" }),
    400,
  );

  const host = await openClient(url(base, channel, "host"), { admissionProof: correctProof });
  assert.equal((await host.next()).type, "waiting");
  assert.equal(
    await rejectedStatus(url(base, channel, "viewer"), { admissionProof: wrongProof }),
    404,
  );

  const viewer = await openClient(url(base, channel, "viewer"), {
    admissionProof: correctProof,
  });
  const [hostReady, viewerReady] = await Promise.all([
    host.next((message) => message.type === "ready"),
    viewer.next((message) => message.type === "ready"),
  ]);
  assert.equal(hostReady.role, "host");
  assert.equal(viewerReady.role, "viewer");
  host.socket.close();
  viewer.socket.close();
});

test("invitation TTL closes an unconsumed host and prevents a late viewer", async (t) => {
  let clock = 1_700_000_000_000;
  const { base } = await fixture(
    t,
    { INVITATION_TTL_SECONDS: "1", HEARTBEAT_INTERVAL_MS: "10", PEER_TIMEOUT_MS: "10000" },
    { now: () => clock },
  );
  const channel = "B".repeat(22);
  const host = await openClient(url(base, channel, "host"));
  await host.next((message) => message.type === "waiting");
  clock += 1_001;
  assert.equal((await host.closed()).code, 4408);
  const viewer = await openClient(url(base, channel, "viewer"));
  assert.deepEqual(await viewer.next(), {
    type: "error",
    error: "invitation_unavailable",
  });
  assert.equal((await viewer.closed()).code, 4404);
});

test("per-channel attempt limits reject excess upgrades", async (t) => {
  const { base } = await fixture(t, { CHANNEL_ATTEMPT_LIMIT: "2" });
  const channel = "C".repeat(22);
  const host = await openClient(url(base, channel, "host"));
  await host.next();
  const viewer = await openClient(url(base, channel, "viewer"));
  await Promise.all([
    host.next((message) => message.type === "ready"),
    viewer.next((message) => message.type === "ready"),
  ]);
  assert.equal(await rejectedStatus(url(base, channel, "viewer")), 429);
  host.socket.close();
  viewer.socket.close();
});

test("per-IP attempt limits apply across different channels", async (t) => {
  const { base } = await fixture(t, { IP_ATTEMPT_LIMIT: "1" });
  const first = await openClient(url(base, "G".repeat(22), "host"));
  await first.next();
  assert.equal(await rejectedStatus(url(base, "H".repeat(22), "host")), 429);
  first.socket.close();
});

test("message rates are enforced across both peers in a channel", async (t) => {
  const { base } = await fixture(t, { CHANNEL_MESSAGE_LIMIT: "2" });
  const channel = "D".repeat(22);
  const host = await openClient(url(base, channel, "host"));
  await host.next();
  const viewer = await openClient(url(base, channel, "viewer"));
  await Promise.all([
    host.next((message) => message.type === "ready"),
    viewer.next((message) => message.type === "ready"),
  ]);
  const envelope = Buffer.from("ciphertext").toString("base64url");
  host.socket.send(JSON.stringify({ type: "signal", seq: 0, envelope }));
  await viewer.next((message) => message.type === "signal");
  host.socket.send(JSON.stringify({ type: "signal", seq: 1, envelope }));
  await viewer.next((message) => message.type === "signal");
  host.socket.send(JSON.stringify({ type: "signal", seq: 2, envelope }));
  assert.equal((await host.next((message) => message.type === "error")).error, "rate_limited");
  assert.equal((await host.closed()).code, 4429);
  viewer.socket.close();
});

test("per-IP message limits are enforced independently of the channel limit", async (t) => {
  const { base } = await fixture(t, { IP_MESSAGE_LIMIT: "1" });
  const channel = "I".repeat(22);
  const host = await openClient(url(base, channel, "host"));
  await host.next();
  const viewer = await openClient(url(base, channel, "viewer"));
  await Promise.all([
    host.next((message) => message.type === "ready"),
    viewer.next((message) => message.type === "ready"),
  ]);
  const envelope = Buffer.from("ciphertext").toString("base64url");
  host.socket.send(JSON.stringify({ type: "signal", seq: 0, envelope }));
  await viewer.next((message) => message.type === "signal");
  host.socket.send(JSON.stringify({ type: "signal", seq: 1, envelope }));
  assert.equal((await host.next((message) => message.type === "error")).error, "rate_limited");
  assert.equal((await host.closed()).code, 4429);
  viewer.socket.close();
});

test("unexpected sequence numbers are rejected instead of forwarded", async (t) => {
  const { base } = await fixture(t);
  const channel = "E".repeat(22);
  const host = await openClient(url(base, channel, "host"));
  await host.next();
  const viewer = await openClient(url(base, channel, "viewer"));
  await Promise.all([
    host.next((message) => message.type === "ready"),
    viewer.next((message) => message.type === "ready"),
  ]);
  host.socket.send(
    JSON.stringify({ type: "signal", seq: 1, envelope: Buffer.from("sealed").toString("base64url") }),
  );
  assert.equal((await host.next((message) => message.type === "error")).error, "unexpected_sequence");
  assert.equal((await host.closed()).code, 4400);
  viewer.socket.close();
});

test("heartbeat terminates a peer that does not answer pings", async (t) => {
  const { base } = await fixture(t, { HEARTBEAT_INTERVAL_MS: "10", PEER_TIMEOUT_MS: "20" });
  const host = await openClient(url(base, "F".repeat(22), "host"), { disablePong: true });
  await host.next();
  assert.equal((await host.closed(500)).code, 1006);
});
