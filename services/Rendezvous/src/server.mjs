import http from "node:http";
import { timingSafeEqual } from "node:crypto";
import { URL } from "node:url";
import WebSocket, { WebSocketServer } from "ws";
import { loadConfig } from "./config.mjs";
import {
  ADMISSION_PROOF_HEADER,
  CHANNEL_HEADER,
  ROLE_HEADER,
  decodeAdmissionProof,
  validateJoin,
  validateSignal,
} from "./protocol.mjs";
import { createIceServerProvider } from "./ice-server-provider.mjs";
import { FixedWindowLimiter } from "./rate-limiter.mjs";

// The Node rendezvous implementation is a signaling coordinator, not a media relay: it forwards
// end-to-end-encrypted envelopes and provisions ICE metadata while WebRTC carries audio/video.
const closeReasons = Object.freeze({
  invalid: [4400, "invalid request"],
  unavailable: [4404, "invitation unavailable"],
  expired: [4408, "invitation expired"],
  conflict: [4409, "role already claimed"],
  rate: [4429, "rate limit exceeded"],
  provisioning: [4503, "ICE provisioning unavailable"],
});

const json = (response, status, value) => {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "cache-control": "no-store",
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
  });
  response.end(body);
};

const rejectUpgrade = (socket, status, code, retryAfterMs) => {
  const phrases = { 400: "Bad Request", 404: "Not Found", 409: "Conflict", 429: "Too Many Requests" };
  const body = JSON.stringify({ error: code });
  const retry = retryAfterMs ? `Retry-After: ${Math.max(1, Math.ceil(retryAfterMs / 1_000))}\r\n` : "";
  socket.end(
    `HTTP/1.1 ${status} ${phrases[status] ?? "Error"}\r\n` +
      "Connection: close\r\n" +
      "Cache-Control: no-store\r\n" +
      "Content-Type: application/json\r\n" +
      `Content-Length: ${Buffer.byteLength(body)}\r\n` +
      retry +
      `\r\n${body}`,
  );
};

const send = (socket, value) => {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(value));
};

const admissionProofsMatch = (expected, received) => timingSafeEqual(expected, received);

/**
 * Resolves the rate-limit identity at the configured reverse-proxy trust depth.
 * Only deployments that control every trusted hop should set `trustedHops` above zero.
 */
function clientIp(request, trustedHops) {
  const remote = request.socket.remoteAddress ?? "unknown";
  if (trustedHops === 0) return remote;
  const forwarded = String(request.headers["x-forwarded-for"] ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  const chain = [...forwarded, remote];
  return chain[Math.max(0, chain.length - 1 - trustedHops)] ?? remote;
}

/**
 * Constructs an independently startable rendezvous server.
 *
 * Dependency injection keeps protocol, time, randomness, ICE provisioning, and logging testable
 * without weakening the production defaults.
 *
 * @param {object} [options] Optional validated config and test dependencies.
 * @returns {{server: import("node:http").Server, start: Function, stop: Function}}
 */
export function createRendezvousServer(options = {}) {
  const config = options.config ?? loadConfig();
  const now = options.now ?? Date.now;
  const randomBytes = options.randomBytes;
  const logger = options.logger ?? console;
  const iceServerProvider =
    options.iceServerProvider ??
    createIceServerProvider(config, { now, randomBytes, fetchImpl: options.fetchImpl });
  const invitations = new Map();
  const peers = new Set();
  const limits = {
    ipAttempts: new FixedWindowLimiter({ limit: config.ipAttemptLimit, windowMs: config.rateWindowMs }),
    channelAttempts: new FixedWindowLimiter({ limit: config.channelAttemptLimit, windowMs: config.rateWindowMs }),
    ipMessages: new FixedWindowLimiter({ limit: config.ipMessageLimit, windowMs: config.rateWindowMs }),
    channelMessages: new FixedWindowLimiter({ limit: config.channelMessageLimit, windowMs: config.rateWindowMs }),
  };

  const server = http.createServer((request, response) => {
    const url = new URL(request.url ?? "/", "http://localhost");
    if ((request.method === "GET" || request.method === "HEAD") && url.pathname === "/healthz") {
      let pendingInvitations = 0;
      let activeSessions = 0;
      for (const invitation of invitations.values()) {
        if (!invitation.consumed) pendingInvitations += 1;
        else if (invitation.host || invitation.viewer) activeSessions += 1;
      }
      json(response, 200, { ok: true, pendingInvitations, activeSessions });
      return;
    }
    json(response, 404, { error: "not_found" });
  });

  const wss = new WebSocketServer({
    noServer: true,
    clientTracking: false,
    maxPayload: config.maxMessageBytes,
    perMessageDeflate: false,
  });

  const removeInvitation = (channel, invitation, reason) => {
    if (invitations.get(channel) !== invitation) return;
    invitations.delete(channel);
    for (const peer of [invitation.host, invitation.viewer]) {
      if (peer?.socket.readyState === WebSocket.OPEN) peer.socket.close(...reason);
    }
  };

  const onClose = (peer) => {
    if (!peers.delete(peer)) return;
    const invitation = invitations.get(peer.channel);
    if (!invitation) return;
    if (invitation[peer.role] === peer) invitation[peer.role] = undefined;
    if (invitation.provisioningState === "pending") {
      removeInvitation(peer.channel, invitation, closeReasons.unavailable);
      return;
    }
    const partnerRole = peer.role === "host" ? "viewer" : "host";
    const partner = invitation[partnerRole];
    if (partner) send(partner.socket, { type: "peer-left", role: peer.role });
    if (invitation.consumed && !invitation.host && !invitation.viewer) {
      // Retain a bounded tombstone so a consumed channel cannot immediately be replayed as a new invitation.
      invitation.retireAt = now() + config.invitationTtlMs;
    }
  };

  const closeWithError = (peer, error, closeReason = closeReasons.invalid) => {
    send(peer.socket, { type: "error", error });
    peer.socket.close(...closeReason);
  };

  const rejectRegisteredSocket = (socket, error, closeReason) => {
    send(socket, { type: "error", error });
    socket.close(...closeReason);
  };

  const onMessage = (peer, data, isBinary) => {
    const timestamp = now();
    const ipRate = limits.ipMessages.take(peer.ip, timestamp);
    const channelRate = limits.channelMessages.take(peer.channel, timestamp);
    if (!ipRate.allowed || !channelRate.allowed) {
      closeWithError(peer, "rate_limited", closeReasons.rate);
      return;
    }
    if (isBinary || data.byteLength > config.maxMessageBytes) {
      closeWithError(peer, "invalid_message");
      return;
    }
    const result = validateSignal(data.toString("utf8"), {
      expectedSequence: peer.lastSequence + 1,
      maxSequence: config.maxSequence,
      maxEnvelopeBytes: config.maxEnvelopeBytes,
    });
    if (result.error) {
      closeWithError(peer, result.error);
      return;
    }
    const invitation = invitations.get(peer.channel);
    const partnerRole = peer.role === "host" ? "viewer" : "host";
    const partner = invitation?.[partnerRole];
    if (!partner || partner.socket.readyState !== WebSocket.OPEN) {
      send(peer.socket, { type: "error", error: "peer_unavailable" });
      return;
    }
    peer.lastSequence = result.value.seq;
    send(partner.socket, {
      type: "signal",
      from: peer.role,
      seq: result.value.seq,
      envelope: result.value.envelope,
    });
  };

  const sendReady = (peer, invitation, iceServers) => {
    send(peer.socket, {
      type: "ready",
      role: peer.role,
      invitationExpiresAt: new Date(invitation.expiresAt).toISOString(),
      iceServers,
    });
  };

  const provisionSession = (channel, invitation) => {
    if (invitation.provisioningState !== "idle") return;
    const host = invitation.host;
    const viewer = invitation.viewer;
    if (!host || !viewer) return;
    invitation.provisioningState = "pending";

    // Credentials are provisioned per peer only after both authenticated roles are present. A
    // failed or stale asynchronous transition retires the whole invitation rather than exposing
    // a partially ready session.
    void Promise.all([
      Promise.resolve().then(() => iceServerProvider({ role: "host" })),
      Promise.resolve().then(() => iceServerProvider({ role: "viewer" })),
    ])
      .then(([hostIceServers, viewerIceServers]) => {
        if (
          !Array.isArray(hostIceServers) ||
          !Array.isArray(viewerIceServers) ||
          invitations.get(channel) !== invitation ||
          invitation.host !== host ||
          invitation.viewer !== viewer ||
          host.socket.readyState !== WebSocket.OPEN ||
          viewer.socket.readyState !== WebSocket.OPEN
        ) {
          throw new Error("ICE provisioning transition failed");
        }
        invitation.provisioningState = "ready";
        sendReady(host, invitation, hostIceServers);
        sendReady(viewer, invitation, viewerIceServers);
      })
      .catch(() => {
        if (invitations.get(channel) !== invitation) return;
        invitation.provisioningState = "failed";
        logger.error?.("AudioStreamer ICE credential provisioning failed");
        for (const peer of [invitation.host, invitation.viewer]) {
          if (peer) send(peer.socket, { type: "error", error: "ice_server_unavailable" });
        }
        removeInvitation(channel, invitation, closeReasons.provisioning);
      });
  };

  const register = (socket, channel, role, ip, admissionProof) => {
    const timestamp = now();
    let invitation = invitations.get(channel);
    if (role === "host") {
      if (!invitation) {
        invitation = {
          createdAt: timestamp,
          expiresAt: timestamp + config.invitationTtlMs,
          consumed: false,
          admissionProof: Buffer.from(admissionProof),
          host: undefined,
          viewer: undefined,
          retireAt: undefined,
          provisioningState: "idle",
        };
        invitations.set(channel, invitation);
      }
      if (invitation.consumed && !invitation.host && !invitation.viewer) {
        rejectRegisteredSocket(socket, "role_already_claimed", closeReasons.conflict);
        return;
      }
      if (invitation.host) {
        rejectRegisteredSocket(socket, "role_already_claimed", closeReasons.conflict);
        return;
      }
    } else {
      if (!invitation || !invitation.host) {
        rejectRegisteredSocket(socket, "invitation_unavailable", closeReasons.unavailable);
        return;
      }
      if (timestamp >= invitation.expiresAt) {
        removeInvitation(channel, invitation, closeReasons.expired);
        rejectRegisteredSocket(socket, "invitation_expired", closeReasons.expired);
        return;
      }
      if (invitation.consumed || invitation.viewer) {
        rejectRegisteredSocket(socket, "role_already_claimed", closeReasons.conflict);
        return;
      }
      // The first admitted viewer permanently consumes this invitation, even if it disconnects.
      // This makes the invitation a one-time capability rather than a reusable password.
      invitation.consumed = true;
    }

    const peer = { socket, channel, role, ip, lastSequence: -1, lastPongAt: timestamp };
    invitation[role] = peer;
    peers.add(peer);
    socket.on("pong", () => {
      peer.lastPongAt = now();
    });
    socket.on("message", (data, isBinary) => onMessage(peer, data, isBinary));
    socket.once("close", () => onClose(peer));
    socket.once("error", () => {});

    if (invitation.host && invitation.viewer) {
      provisionSession(channel, invitation);
    } else {
      send(socket, { type: "waiting", invitationExpiresAt: new Date(invitation.expiresAt).toISOString() });
    }
  };

  server.on("upgrade", (request, socket, head) => {
    const ip = clientIp(request, config.trustProxyHops);
    const timestamp = now();
    const ipRate = limits.ipAttempts.take(ip, timestamp);
    if (!ipRate.allowed) {
      rejectUpgrade(socket, 429, "rate_limited", ipRate.retryAfterMs);
      return;
    }

    const url = new URL(request.url ?? "/", "http://localhost");
    if (url.pathname !== "/v1/rendezvous") {
      rejectUpgrade(socket, 404, "not_found");
      return;
    }
    if (url.search !== "") {
      rejectUpgrade(socket, 400, "invalid_join");
      return;
    }
    const channel = request.headers[CHANNEL_HEADER];
    const role = request.headers[ROLE_HEADER];
    const joinError = validateJoin(channel, role);
    if (joinError) {
      rejectUpgrade(socket, 400, joinError);
      return;
    }
    const channelRate = limits.channelAttempts.take(channel, timestamp);
    if (!channelRate.allowed) {
      rejectUpgrade(socket, 429, "rate_limited", channelRate.retryAfterMs);
      return;
    }
    const admissionProof = decodeAdmissionProof(request.headers[ADMISSION_PROOF_HEADER]);
    if (!admissionProof) {
      rejectUpgrade(socket, 400, "invalid_admission");
      return;
    }

    const existingInvitation = invitations.get(channel);
    if (
      existingInvitation &&
      !admissionProofsMatch(existingInvitation.admissionProof, admissionProof)
    ) {
      rejectUpgrade(socket, 404, "invitation_unavailable");
      return;
    }

    wss.handleUpgrade(request, socket, head, (webSocket) =>
      register(webSocket, channel, role, ip, admissionProof),
    );
  });

  const heartbeat = setInterval(() => {
    const timestamp = now();
    for (const peer of peers) {
      if (timestamp - peer.lastPongAt > config.peerTimeoutMs) {
        peer.socket.terminate();
      } else if (peer.socket.readyState === WebSocket.OPEN) {
        peer.socket.ping();
      }
    }
    for (const [channel, invitation] of invitations) {
      if (!invitation.consumed && timestamp >= invitation.expiresAt) {
        removeInvitation(channel, invitation, closeReasons.expired);
      } else if (
        invitation.consumed &&
        !invitation.host &&
        !invitation.viewer &&
        timestamp >= invitation.retireAt
      ) {
        invitations.delete(channel);
      }
    }
    for (const limiter of Object.values(limits)) limiter.prune(timestamp);
  }, config.heartbeatIntervalMs);
  heartbeat.unref();

  const start = () =>
    new Promise((resolve, reject) => {
      const onError = (error) => reject(error);
      server.once("error", onError);
      server.listen(config.port, config.host, () => {
        server.off("error", onError);
        const address = server.address();
        logger.info?.("AudioStreamer rendezvous listening", {
          host: typeof address === "object" ? address.address : config.host,
          port: typeof address === "object" ? address.port : config.port,
        });
        resolve(address);
      });
    });

  const stop = () =>
    new Promise((resolve, reject) => {
      clearInterval(heartbeat);
      for (const peer of peers) peer.socket.terminate();
      wss.close(() => {
        if (!server.listening) {
          resolve();
          return;
        }
        server.close((error) => (error ? reject(error) : resolve()));
      });
    });

  return Object.freeze({ server, start, stop });
}
