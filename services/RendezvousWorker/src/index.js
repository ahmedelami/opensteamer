import { DurableObject } from "cloudflare:workers";
import { TurnProvisioningError, iceServersForJoin } from "./ice.js";
import {
  AVAILABILITY_WEBSOCKET_PROTOCOL,
  HEADER,
  LIMITS,
  PAIRING_WEBSOCKET_PROTOCOL,
  admissionProofsMatch,
  validateAvailabilitySignal,
  validateJoinHeaders,
  validateSignal,
} from "./protocol.js";

const STORAGE_KEY = "invitation";
const AVAILABILITY_STORAGE_KEY = "availability";
const STATE_VERSION = 1;
const AVAILABILITY_STATE_VERSION = 2;
const OPEN = 1;
const CLOSED = 3;

const CLOSE = Object.freeze({
  invalid: [4400, "invalid request"],
  unavailable: [4404, "invitation unavailable"],
  availabilityUnavailable: [4404, "availability unavailable"],
  expired: [4408, "invitation expired"],
  conflict: [4409, "role already claimed"],
  rate: [4429, "rate limit exceeded"],
  retry: [1013, "try again later"],
});

const responseHeaders = Object.freeze({
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
});

const json = (value, status = 200, extraHeaders = undefined) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { ...responseHeaders, ...extraHeaders },
  });

const parseDurationMs = (value, fallbackSeconds) => {
  const seconds = value === undefined || value === "" ? fallbackSeconds : Number(value);
  if (!Number.isSafeInteger(seconds) || seconds < 1 || seconds > 3_600) {
    throw new Error("invalid service configuration");
  }
  return seconds * 1_000;
};

const safeSend = (socket, value) => {
  if (socket.readyState !== OPEN) return false;
  try {
    socket.send(JSON.stringify(value));
    return true;
  } catch {
    return false;
  }
};

const safeClose = (socket, [code, reason]) => {
  try {
    socket.close(code, reason);
  } catch {
    // A concurrent peer close is already sufficient.
  }
};

const validInvitation = (value) =>
  value !== null &&
  typeof value === "object" &&
  value.version === STATE_VERSION &&
  typeof value.channel === "string" &&
  typeof value.admissionProof === "string" &&
  typeof value.generation === "string" &&
  (value.mode === undefined || value.mode === "pairing") &&
  Number.isSafeInteger(value.expiresAt) &&
  typeof value.consumed === "boolean" &&
  (value.retireAt === null || Number.isSafeInteger(value.retireAt));

const validAvailability = (value) =>
  value !== null &&
  typeof value === "object" &&
  value.version === AVAILABILITY_STATE_VERSION &&
  value.mode === "availability" &&
  typeof value.channel === "string" &&
  typeof value.hostAdmissionProof === "string" &&
  typeof value.viewerAdmissionProof === "string" &&
  typeof value.generation === "string";

const validAttachment = (value) =>
  value !== null &&
  typeof value === "object" &&
  value.version === STATE_VERSION &&
  value.mode === undefined &&
  (value.role === "host" || value.role === "viewer" || value.role === "rejected") &&
  typeof value.generation === "string" &&
  Number.isSafeInteger(value.nextSequence) &&
  Number.isSafeInteger(value.lastActivityAt) &&
  Number.isSafeInteger(value.rateWindowStartedAt) &&
  Number.isSafeInteger(value.rateCount) &&
  typeof value.departed === "boolean";

const validAvailabilityAttachment = (value) =>
  value !== null &&
  typeof value === "object" &&
  value.version === STATE_VERSION &&
  value.mode === "availability" &&
  (value.role === "host" || value.role === "viewer" || value.role === "rejected") &&
  typeof value.generation === "string" &&
  (value.exchangeID === null || typeof value.exchangeID === "string") &&
  Number.isSafeInteger(value.nextSequence) &&
  Number.isSafeInteger(value.lastActivityAt) &&
  Number.isSafeInteger(value.rateWindowStartedAt) &&
  Number.isSafeInteger(value.rateCount) &&
  typeof value.departed === "boolean";

const socketAttachment = (socket) => {
  try {
    const value = socket.deserializeAttachment();
    return validAvailabilityAttachment(value) || validAttachment(value) ? value : undefined;
  } catch {
    return undefined;
  }
};

const newAttachment = (role, generation, now) => ({
  version: STATE_VERSION,
  role,
  generation,
  nextSequence: 0,
  lastActivityAt: now,
  rateWindowStartedAt: now,
  rateCount: 0,
  departed: false,
});

const newAvailabilityAttachment = (role, generation, now, exchangeID = null) => ({
  version: STATE_VERSION,
  mode: "availability",
  role,
  generation,
  exchangeID,
  nextSequence: 0,
  lastActivityAt: now,
  rateWindowStartedAt: now,
  rateCount: 0,
  departed: false,
});

const randomExchangeID = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
};

export class RendezvousSession extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
    this.env = env;
    this.invitation = null;
    this.availability = null;
    this.corruptState = false;
    this.mutationQueue = Promise.resolve();
    this.initialized = ctx.blockConcurrencyWhile(async () => {
      const [storedInvitation, storedAvailability] = await Promise.all([
        ctx.storage.get(STORAGE_KEY),
        ctx.storage.get(AVAILABILITY_STORAGE_KEY),
      ]);
      if (storedInvitation !== undefined && !validInvitation(storedInvitation)) {
        this.corruptState = true;
        return;
      }
      if (storedAvailability !== undefined && !validAvailability(storedAvailability)) {
        this.corruptState = true;
        return;
      }
      if (storedInvitation !== undefined && storedAvailability !== undefined) {
        this.corruptState = true;
        return;
      }
      this.invitation = storedInvitation ?? null;
      this.availability = storedAvailability ?? null;
    });
  }

  fetch(request) {
    return this.serializeMutation(() => this.handleJoin(request));
  }

  serializeMutation(operation) {
    const result = this.mutationQueue.then(operation);
    this.mutationQueue = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  async handleJoin(request) {
    await this.initialized;
    if (this.corruptState) return json({ error: "service_unavailable" }, 503);

    const url = new URL(request.url);
    const expectedMode = url.pathname === "/v2/availability" ? "availability" : "invitation";
    if (
      request.method !== "GET" ||
      (url.pathname !== "/v1/rendezvous" && url.pathname !== "/v2/availability") ||
      url.search !== "" ||
      request.headers.get("Upgrade")?.toLowerCase() !== "websocket"
    ) {
      return json({ error: "invalid_join" }, 400);
    }
    const join = validateJoinHeaders(request.headers, expectedMode);
    if (join.error) return json({ error: join.error }, 400);
    if (join.value.mode === "availability") {
      if (this.invitation) return json({ error: "service_unavailable" }, 503);
      return this.handleAvailabilityJoin(join.value);
    }
    if (this.availability) return json({ error: "service_unavailable" }, 503);
    const { channel, role, admission, proofBytes, mode } = join.value;
    const now = Date.now();

    if (this.invitation && !admissionProofsMatch(this.invitation.admissionProof, proofBytes)) {
      return json({ error: "invitation_unavailable" }, 404);
    }

    if (this.invitation && !this.invitation.consumed && now >= this.invitation.expiresAt) {
      const expiredGeneration = this.invitation.generation;
      await this.expireInvitation(expiredGeneration);
      if (role === "viewer") {
        return this.rejectWebSocket("invitation_expired", CLOSE.expired, mode);
      }
    }

    if (!this.invitation) {
      if (role !== "host") {
        return this.rejectWebSocket("invitation_unavailable", CLOSE.unavailable, mode);
      }
      const invitationTtlMs = parseDurationMs(this.env.INVITATION_TTL_SECONDS, 300);
      this.invitation = {
        version: STATE_VERSION,
        channel,
        admissionProof: admission,
        generation: crypto.randomUUID(),
        expiresAt: now + invitationTtlMs,
        consumed: false,
        retireAt: null,
        ...(mode === "pairing" ? { mode: "pairing" } : {}),
      };
      await this.ctx.storage.put(STORAGE_KEY, this.invitation);
      await this.ctx.storage.setAlarm(this.invitation.expiresAt);
    }

    const invitation = this.invitation;
    if (invitation.channel !== channel) return json({ error: "invitation_unavailable" }, 404);
    if ((invitation.mode ?? "invitation") !== mode) {
      return json({ error: "invitation_unavailable" }, 404);
    }

    const occupiedRole = this.roleSockets(role, invitation.generation, true).length > 0;
    if (occupiedRole) {
      return this.rejectWebSocket("role_already_claimed", CLOSE.conflict, mode);
    }

    const oppositeRole = role === "host" ? "viewer" : "host";
    let opposite = this.firstOpenRoleSocket(oppositeRole, invitation.generation);
    if (role === "viewer") {
      if (!opposite) {
        return this.rejectWebSocket("invitation_unavailable", CLOSE.unavailable, mode);
      }
      if (invitation.consumed) {
        return this.rejectWebSocket("role_already_claimed", CLOSE.conflict, mode);
      }
    } else if (invitation.consumed && !opposite) {
      return this.rejectWebSocket("role_already_claimed", CLOSE.conflict, mode);
    }

    let iceServers;
    if (opposite) {
      if (mode === "pairing") {
        iceServers = [];
      } else {
        try {
          iceServers = await iceServersForJoin(this.env);
        } catch (error) {
          if (error instanceof TurnProvisioningError) {
            return this.rejectWebSocket("turn_unavailable", CLOSE.retry, mode);
          }
          return this.rejectWebSocket("service_unavailable", CLOSE.retry, mode);
        }
      }

      if (this.invitation !== invitation || this.invitation.generation !== invitation.generation) {
        return this.rejectWebSocket("invitation_unavailable", CLOSE.unavailable, mode);
      }
      opposite = this.firstOpenRoleSocket(oppositeRole, invitation.generation);
      if (!opposite || this.roleSockets(role, invitation.generation, true).length > 0) {
        return this.rejectWebSocket(
          opposite ? "role_already_claimed" : "invitation_unavailable",
          opposite ? CLOSE.conflict : CLOSE.unavailable,
          mode,
        );
      }
    }

    if (role === "viewer") {
      invitation.consumed = true;
      invitation.retireAt = null;
      await this.ctx.storage.put(STORAGE_KEY, invitation);
    }

    const accepted = this.acceptWebSocket(role, invitation.generation, mode);
    if (!opposite) {
      safeSend(accepted.server, {
        type: "waiting",
        invitationExpiresAt: new Date(invitation.expiresAt).toISOString(),
      });
      return accepted.response;
    }

    const currentSocket = accepted.server;
    const readyForCurrent = {
      type: "ready",
      role,
      invitationExpiresAt: new Date(invitation.expiresAt).toISOString(),
      iceServers,
    };
    const readyForOpposite = { ...readyForCurrent, role: oppositeRole };
    if (!safeSend(opposite, readyForOpposite) || !safeSend(currentSocket, readyForCurrent)) {
      safeClose(opposite, CLOSE.retry);
      safeClose(currentSocket, CLOSE.retry);
    }
    return accepted.response;
  }

  async handleAvailabilityJoin({
    channel,
    role,
    admission,
    proofBytes,
    viewerAdmission,
    viewerProofBytes,
  }) {
    const now = Date.now();
    const expectedProof =
      role === "host"
        ? this.availability?.hostAdmissionProof
        : this.availability?.viewerAdmissionProof;
    if (expectedProof && !admissionProofsMatch(expectedProof, proofBytes)) {
      return json({ error: "availability_unavailable" }, 404);
    }
    if (
      this.availability &&
      role === "host" &&
      !admissionProofsMatch(this.availability.viewerAdmissionProof, viewerProofBytes)
    ) {
      return json({ error: "availability_unavailable" }, 404);
    }

    if (!this.availability) {
      if (role !== "host" || !viewerAdmission || !viewerProofBytes) {
        return this.rejectAvailabilityWebSocket(
          "availability_unavailable",
          CLOSE.availabilityUnavailable,
        );
      }
      this.availability = {
        version: AVAILABILITY_STATE_VERSION,
        mode: "availability",
        channel,
        hostAdmissionProof: admission,
        viewerAdmissionProof: viewerAdmission,
        generation: crypto.randomUUID(),
      };
      await this.ctx.storage.put(AVAILABILITY_STORAGE_KEY, this.availability);
    }

    const availability = this.availability;
    if (availability.channel !== channel) {
      return json({ error: "availability_unavailable" }, 404);
    }
    if (this.availabilityRoleSockets(role, availability.generation, undefined, true).length > 0) {
      return this.rejectAvailabilityWebSocket("role_already_claimed", CLOSE.conflict);
    }

    if (role === "host") {
      if (
        this.availabilityRoleSockets("viewer", availability.generation, undefined, true).length > 0
      ) {
        return this.rejectAvailabilityWebSocket(
          "availability_unavailable",
          CLOSE.availabilityUnavailable,
        );
      }
      const accepted = this.acceptAvailabilityWebSocket("host", availability.generation, null);
      safeSend(accepted.server, { type: "availability-waiting" });
      return accepted.response;
    }

    const host = this.firstOpenAvailabilityRoleSocket("host", availability.generation, null);
    if (!host) {
      return this.rejectAvailabilityWebSocket(
        "availability_unavailable",
        CLOSE.availabilityUnavailable,
      );
    }

    const exchangeID = randomExchangeID();
    const hostAttachment = socketAttachment(host);
    if (!hostAttachment || hostAttachment.mode !== "availability") {
      return this.rejectAvailabilityWebSocket(
        "availability_unavailable",
        CLOSE.availabilityUnavailable,
      );
    }
    hostAttachment.exchangeID = exchangeID;
    hostAttachment.nextSequence = 0;
    hostAttachment.lastActivityAt = now;
    host.serializeAttachment(hostAttachment);

    const accepted = this.acceptAvailabilityWebSocket(
      "viewer",
      availability.generation,
      exchangeID,
    );
    const hostReady = safeSend(host, {
      type: "availability-ready",
      role: "host",
      exchangeID,
    });
    const viewerReady = safeSend(accepted.server, {
      type: "availability-ready",
      role: "viewer",
      exchangeID,
    });
    if (!hostReady || !viewerReady) {
      hostAttachment.exchangeID = null;
      hostAttachment.nextSequence = 0;
      try {
        host.serializeAttachment(hostAttachment);
      } catch {
        // A failed ready send can coincide with the host disconnecting.
      }
      safeClose(accepted.server, CLOSE.retry);
      if (hostReady) {
        safeSend(host, { type: "availability-peer-left", role: "viewer", exchangeID });
        safeSend(host, { type: "availability-waiting" });
      } else {
        safeClose(host, CLOSE.retry);
      }
    }
    return accepted.response;
  }

  acceptWebSocket(role, generation, mode = "invitation") {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment(newAttachment(role, generation, Date.now()));
    return {
      server,
      response: new Response(null, {
        status: 101,
        webSocket: client,
        headers: {
          "Cache-Control": "no-store",
          ...(mode === "pairing"
            ? { [HEADER.webSocketProtocol]: PAIRING_WEBSOCKET_PROTOCOL }
            : {}),
        },
      }),
    };
  }

  rejectWebSocket(error, closeReason, mode = this.invitation?.mode ?? "invitation") {
    const generation = this.invitation?.generation ?? "rejected";
    const accepted = this.acceptWebSocket("rejected", generation, mode);
    safeSend(accepted.server, { type: "error", error });
    safeClose(accepted.server, closeReason);
    return accepted.response;
  }

  acceptAvailabilityWebSocket(role, generation, exchangeID) {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment(
      newAvailabilityAttachment(role, generation, Date.now(), exchangeID),
    );
    return {
      server,
      response: new Response(null, {
        status: 101,
        webSocket: client,
        headers: {
          "Cache-Control": "no-store",
          [HEADER.webSocketProtocol]: AVAILABILITY_WEBSOCKET_PROTOCOL,
        },
      }),
    };
  }

  rejectAvailabilityWebSocket(error, closeReason) {
    const generation = this.availability?.generation ?? "rejected";
    const accepted = this.acceptAvailabilityWebSocket("rejected", generation, null);
    safeSend(accepted.server, { type: "error", error });
    safeClose(accepted.server, closeReason);
    return accepted.response;
  }

  roleSockets(role, generation, includeClosing = false) {
    return this.ctx.getWebSockets(role).filter((socket) => {
      const attachment = socketAttachment(socket);
      return (
        attachment?.role === role &&
        attachment.generation === generation &&
        !attachment.departed &&
        (includeClosing ? socket.readyState !== CLOSED : socket.readyState === OPEN)
      );
    });
  }

  firstOpenRoleSocket(role, generation) {
    return this.roleSockets(role, generation, false)[0];
  }

  availabilityRoleSockets(role, generation, exchangeID = undefined, includeClosing = false) {
    return this.ctx.getWebSockets(role).filter((socket) => {
      const attachment = socketAttachment(socket);
      return (
        attachment?.mode === "availability" &&
        attachment.role === role &&
        attachment.generation === generation &&
        (exchangeID === undefined || attachment.exchangeID === exchangeID) &&
        !attachment.departed &&
        (includeClosing ? socket.readyState !== CLOSED : socket.readyState === OPEN)
      );
    });
  }

  firstOpenAvailabilityRoleSocket(role, generation, exchangeID = undefined) {
    return this.availabilityRoleSockets(role, generation, exchangeID, false)[0];
  }

  webSocketMessage(socket, message) {
    const attachment = socketAttachment(socket);
    if (attachment?.mode === "availability") {
      this.handleAvailabilityMessage(socket, message, attachment);
      return;
    }
    const invitation = this.invitation;
    if (
      !attachment ||
      (attachment.role !== "host" && attachment.role !== "viewer") ||
      !invitation ||
      attachment.generation !== invitation.generation
    ) {
      safeClose(socket, CLOSE.invalid);
      return;
    }

    const now = Date.now();
    attachment.lastActivityAt = now;
    if (now - attachment.rateWindowStartedAt >= LIMITS.messageRateWindowMs) {
      attachment.rateWindowStartedAt = now;
      attachment.rateCount = 0;
    }
    attachment.rateCount += 1;
    socket.serializeAttachment(attachment);
    if (attachment.rateCount > LIMITS.messageRateLimit) {
      safeSend(socket, { type: "error", error: "rate_limited" });
      safeClose(socket, CLOSE.rate);
      return;
    }

    if (typeof message !== "string") {
      safeSend(socket, { type: "error", error: "invalid_message" });
      safeClose(socket, CLOSE.invalid);
      return;
    }
    const result = validateSignal(message, {
      channel: invitation.channel,
      role: attachment.role,
      expectedSequence: attachment.nextSequence,
    });
    if (result.error) {
      safeSend(socket, { type: "error", error: result.error });
      safeClose(socket, CLOSE.invalid);
      return;
    }

    const oppositeRole = attachment.role === "host" ? "viewer" : "host";
    const partner = this.firstOpenRoleSocket(oppositeRole, invitation.generation);
    if (!partner) {
      safeSend(socket, { type: "error", error: "peer_unavailable" });
      return;
    }
    if (!safeSend(partner, {
      type: "signal",
      from: attachment.role,
      seq: result.value.seq,
      envelope: result.value.envelope,
    })) {
      safeSend(socket, { type: "error", error: "peer_unavailable" });
      return;
    }

    attachment.nextSequence += 1;
    socket.serializeAttachment(attachment);
  }

  handleAvailabilityMessage(socket, message, attachment) {
    const availability = this.availability;
    if (
      (attachment.role !== "host" && attachment.role !== "viewer") ||
      !availability ||
      attachment.generation !== availability.generation ||
      typeof attachment.exchangeID !== "string"
    ) {
      safeClose(socket, CLOSE.invalid);
      return;
    }

    const now = Date.now();
    attachment.lastActivityAt = now;
    if (now - attachment.rateWindowStartedAt >= LIMITS.messageRateWindowMs) {
      attachment.rateWindowStartedAt = now;
      attachment.rateCount = 0;
    }
    attachment.rateCount += 1;
    socket.serializeAttachment(attachment);
    if (attachment.rateCount > LIMITS.messageRateLimit) {
      safeSend(socket, { type: "error", error: "rate_limited" });
      safeClose(socket, CLOSE.rate);
      return;
    }

    if (typeof message !== "string") {
      safeSend(socket, { type: "error", error: "invalid_message" });
      safeClose(socket, CLOSE.invalid);
      return;
    }
    const result = validateAvailabilitySignal(message, {
      channel: availability.channel,
      role: attachment.role,
      exchangeID: attachment.exchangeID,
      expectedSequence: attachment.nextSequence,
    });
    if (result.error) {
      safeSend(socket, { type: "error", error: result.error });
      safeClose(socket, CLOSE.invalid);
      return;
    }

    const oppositeRole = attachment.role === "host" ? "viewer" : "host";
    const partner = this.firstOpenAvailabilityRoleSocket(
      oppositeRole,
      availability.generation,
      attachment.exchangeID,
    );
    if (!partner) {
      safeSend(socket, { type: "error", error: "peer_unavailable" });
      return;
    }
    if (
      !safeSend(partner, {
        type: "availability-signal",
        from: attachment.role,
        exchangeID: attachment.exchangeID,
        seq: result.value.seq,
        envelope: result.value.envelope,
      })
    ) {
      safeSend(socket, { type: "error", error: "peer_unavailable" });
      return;
    }

    attachment.nextSequence += 1;
    socket.serializeAttachment(attachment);
  }

  async webSocketClose(socket) {
    await this.serializeMutation(() => this.handleDeparture(socket));
  }

  async webSocketError(socket) {
    await this.serializeMutation(() => this.handleDeparture(socket));
  }

  async handleDeparture(socket) {
    const attachment = socketAttachment(socket);
    if (attachment?.mode === "availability") {
      await this.handleAvailabilityDeparture(socket, attachment);
      return;
    }
    if (
      !attachment ||
      attachment.departed ||
      (attachment.role !== "host" && attachment.role !== "viewer")
    ) {
      return;
    }
    attachment.departed = true;
    attachment.lastActivityAt = Date.now();
    try {
      socket.serializeAttachment(attachment);
    } catch {
      // The socket may already be fully detached.
    }

    const invitation = this.invitation;
    if (!invitation || attachment.generation !== invitation.generation) return;
    const oppositeRole = attachment.role === "host" ? "viewer" : "host";
    const partner = this.firstOpenRoleSocket(oppositeRole, invitation.generation);
    if (partner) safeSend(partner, { type: "peer-left", role: attachment.role });

    const remaining = ["host", "viewer"].some(
      (role) => this.roleSockets(role, invitation.generation, true).length > 0,
    );
    if (invitation.consumed && !remaining) {
      invitation.retireAt = Date.now() + parseDurationMs(this.env.TOMBSTONE_TTL_SECONDS, 300);
      await this.ctx.storage.put(STORAGE_KEY, invitation);
      await this.ctx.storage.setAlarm(invitation.retireAt);
    }
  }

  async handleAvailabilityDeparture(socket, attachment) {
    if (
      attachment.departed ||
      (attachment.role !== "host" && attachment.role !== "viewer")
    ) {
      return;
    }
    attachment.departed = true;
    attachment.lastActivityAt = Date.now();
    try {
      socket.serializeAttachment(attachment);
    } catch {
      // The socket may already be fully detached.
    }

    const availability = this.availability;
    if (!availability || attachment.generation !== availability.generation) return;
    const exchangeID = attachment.exchangeID;
    if (typeof exchangeID !== "string") return;

    if (attachment.role === "viewer") {
      const host = this.firstOpenAvailabilityRoleSocket(
        "host",
        availability.generation,
        exchangeID,
      );
      if (!host) return;
      const hostAttachment = socketAttachment(host);
      if (!hostAttachment || hostAttachment.mode !== "availability") return;
      hostAttachment.exchangeID = null;
      hostAttachment.nextSequence = 0;
      hostAttachment.lastActivityAt = Date.now();
      host.serializeAttachment(hostAttachment);
      safeSend(host, { type: "availability-peer-left", role: "viewer", exchangeID });
      safeSend(host, { type: "availability-waiting" });
      return;
    }

    const viewer = this.firstOpenAvailabilityRoleSocket(
      "viewer",
      availability.generation,
      exchangeID,
    );
    if (!viewer) return;
    const viewerAttachment = socketAttachment(viewer);
    if (viewerAttachment?.mode === "availability") {
      viewerAttachment.departed = true;
      viewerAttachment.lastActivityAt = Date.now();
      try {
        viewer.serializeAttachment(viewerAttachment);
      } catch {
        // The viewer can already be closing concurrently with the host.
      }
    }
    safeSend(viewer, { type: "availability-peer-left", role: "host", exchangeID });
    safeClose(viewer, CLOSE.availabilityUnavailable);
  }

  async expireInvitation(generation) {
    if (!this.invitation || this.invitation.generation !== generation) return;
    for (const role of ["host", "viewer"]) {
      for (const socket of this.roleSockets(role, generation, true)) {
        safeSend(socket, { type: "error", error: "invitation_expired" });
        safeClose(socket, CLOSE.expired);
      }
    }
    this.invitation = null;
    await this.ctx.storage.delete(STORAGE_KEY);
  }

  async alarm() {
    await this.initialized;
    if (!this.invitation || this.corruptState) return;
    const now = Date.now();
    if (!this.invitation.consumed && now >= this.invitation.expiresAt) {
      await this.expireInvitation(this.invitation.generation);
      return;
    }
    if (
      this.invitation.consumed &&
      this.invitation.retireAt !== null &&
      now >= this.invitation.retireAt
    ) {
      this.invitation = null;
      await this.ctx.storage.delete(STORAGE_KEY);
    }
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/healthz" && url.search === "") {
      return json({ ok: true });
    }
    if (url.pathname !== "/v1/rendezvous" && url.pathname !== "/v2/availability") {
      return json({ error: "not_found" }, 404);
    }
    if (
      request.method !== "GET" ||
      url.search !== "" ||
      url.protocol !== "https:" ||
      request.headers.get("Upgrade")?.toLowerCase() !== "websocket"
    ) {
      return json({ error: "invalid_join" }, 400);
    }

    const routeMode = url.pathname === "/v2/availability" ? "availability" : "invitation";
    const join = validateJoinHeaders(request.headers, routeMode);
    if (join.error) return json({ error: join.error }, 400);
    const { channel, role, admission, viewerAdmission, mode } = join.value;
    const actor = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const channelRateKey =
      mode === "availability"
        ? `channel:availability:${channel}`
        : mode === "pairing"
          ? `channel:pairing:${channel}`
          : `channel:${channel}`;
    const [actorLimit, channelLimit] = await Promise.all([
      env.JOIN_RATE_LIMITER.limit({ key: `actor:${actor}` }),
      env.JOIN_RATE_LIMITER.limit({ key: channelRateKey }),
    ]);
    if (!actorLimit.success || !channelLimit.success) {
      return json({ error: "rate_limited" }, 429, { "Retry-After": "60" });
    }
    const objectName =
      mode === "availability"
        ? `availability:${channel}`
        : mode === "pairing"
          ? `pairing:${channel}`
          : channel;
    const id = env.RENDEZVOUS.idFromName(objectName);
    const stub = env.RENDEZVOUS.get(id);
    const headers = new Headers({
      Upgrade: "websocket",
      [HEADER.channel]: channel,
      [HEADER.role]: role,
      [HEADER.admission]: admission,
    });
    if (mode === "availability") {
      headers.set(HEADER.mode, mode);
      headers.set(HEADER.webSocketProtocol, AVAILABILITY_WEBSOCKET_PROTOCOL);
      if (viewerAdmission) headers.set(HEADER.viewerAdmission, viewerAdmission);
    } else if (mode === "pairing") {
      headers.set(HEADER.webSocketProtocol, PAIRING_WEBSOCKET_PROTOCOL);
    }
    const internalPath = mode === "availability" ? "/v2/availability" : "/v1/rendezvous";
    return stub.fetch(new Request(`https://rendezvous.internal${internalPath}`, { headers }));
  },
};
