import { randomBytes } from "node:crypto";
import WebSocket from "ws";

// This opt-in smoke test exercises the deployed public WSS boundary with freshly generated,
// process-local capabilities. It never reads or prints a production invitation/access code.
const origin = process.env.AUDIOSTREAMER_RENDEZVOUS_URL;
if (!origin) {
  throw new Error("AUDIOSTREAMER_RENDEZVOUS_URL is required");
}

const endpoint = new URL("/v1/rendezvous", origin);
endpoint.protocol = endpoint.protocol === "https:" ? "wss:" : endpoint.protocol;
if (endpoint.protocol !== "wss:") throw new Error("A public wss:// endpoint is required");

const channel = randomBytes(32).toString("base64url");
const admission = randomBytes(32).toString("base64url");
const wrongAdmission = randomBytes(32).toString("base64url");

const headers = (role, proof = admission) => ({
  "X-AudioStreamer-Channel": channel,
  "X-AudioStreamer-Role": role,
  "X-AudioStreamer-Admission": proof,
});

const createPeer = (role, proof = admission) => {
  const socket = new WebSocket(endpoint, { headers: headers(role, proof) });
  const queued = [];
  const waiters = [];
  socket.on("message", (value) => {
    const message = JSON.parse(value.toString("utf8"));
    const waiter = waiters.shift();
    if (waiter) waiter.resolve(message);
    else queued.push(message);
  });
  return {
    socket,
    nextMessage(timeoutMs = 5_000) {
      if (queued.length > 0) return Promise.resolve(queued.shift());
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("message timeout")), timeoutMs);
        waiters.push({
          resolve(message) {
            clearTimeout(timer);
            resolve(message);
          },
        });
      });
    },
  };
};

const waitForOpen = (peer) =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("open timeout")), 10_000);
    peer.socket.once("open", () => {
      clearTimeout(timer);
      resolve(peer);
    });
    peer.socket.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });

const unexpectedStatus = (url, requestHeaders) =>
  new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { headers: requestHeaders });
    const timer = setTimeout(() => reject(new Error("rejection timeout")), 10_000);
    socket.once("unexpected-response", (_request, response) => {
      clearTimeout(timer);
      const { statusCode } = response;
      response.resume();
      socket.terminate();
      resolve(statusCode);
    });
    socket.once("open", () => {
      clearTimeout(timer);
      socket.terminate();
      reject(new Error("upgrade unexpectedly succeeded"));
    });
    socket.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });

const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

const sealedSignal = (role, sequence) => {
  const envelope = {
    version: 1,
    channelID: channel,
    direction: role === "host" ? "hostToViewer" : "viewerToHost",
    sequence,
    ciphertext: Buffer.from("opaque smoke-test ciphertext").toString("base64"),
  };
  return {
    type: "signal",
    seq: sequence,
    envelope: Buffer.from(JSON.stringify(envelope)).toString("base64url"),
  };
};

const queryURL = new URL(endpoint);
// The assertions below are deployment oracles: strict upgrade routing, viewer-first rejection,
// admission proof enforcement, peer readiness, opaque forwarding, and one-time consumption.
queryURL.searchParams.set("channel", "forbidden");
assert(
  (await unexpectedStatus(queryURL, headers("host"))) === 400,
  "query-based join was not rejected",
);

const viewerFirst = await waitForOpen(createPeer("viewer"));
assert((await viewerFirst.nextMessage()).error === "invitation_unavailable", "viewer-first gate failed");
viewerFirst.socket.terminate();

const host = await waitForOpen(createPeer("host"));
assert((await host.nextMessage()).type === "waiting", "host did not enter waiting state");
assert(
  (await unexpectedStatus(endpoint, headers("viewer", wrongAdmission))) === 404,
  "wrong admission was not rejected before occupancy",
);

const viewer = await waitForOpen(createPeer("viewer"));
const [hostReady, viewerReady] = await Promise.all([host.nextMessage(), viewer.nextMessage()]);
assert(hostReady.type === "ready" && viewerReady.type === "ready", "peers did not become ready");
assert(
  hostReady.iceServers.some((server) => server.urls.some((url) => url.startsWith("stun:"))),
  "ready did not include STUN",
);

const signal = sealedSignal("host", 0);
host.socket.send(JSON.stringify(signal));
const forwarded = await viewer.nextMessage();
assert(
  forwarded.type === "signal" && forwarded.envelope === signal.envelope,
  "opaque signaling envelope changed in transit",
);

const secondViewer = await waitForOpen(createPeer("viewer"));
assert((await secondViewer.nextMessage()).error === "role_already_claimed", "consume-once gate failed");
secondViewer.socket.terminate();
host.socket.close(1000, "done");
viewer.socket.close(1000, "done");

console.log(JSON.stringify({
  ok: true,
  route: "public-wss",
  iceMode: hostReady.iceServers.some((server) =>
    server.urls.some((url) => url.startsWith("turn:") || url.startsWith("turns:")))
    ? "turn"
    : "stun-only",
}));
