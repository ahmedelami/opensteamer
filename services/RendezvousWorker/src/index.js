import { DurableObject } from "cloudflare:workers";
import { TurnProvisioningError, iceServersForJoin } from "./ice.js";
import {
  HEADER,
  LIMITS,
  admissionProofsMatch,
  validateJoinHeaders,
  validateSignal,
} from "./protocol.js";

const STORAGE_KEY = "invitation";
const STATE_VERSION = 1;
const OPEN = 1;
const CLOSED = 3;

const CLOSE = Object.freeze({
  invalid: [4400, "invalid request"],
  unavailable: [4404, "invitation unavailable"],
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
  Number.isSafeInteger(value.expiresAt) &&
  typeof value.consumed === "boolean" &&
  (value.retireAt === null || Number.isSafeInteger(value.retireAt));

const validAttachment = (value) =>
  value !== null &&
  typeof value === "object" &&
  value.version === STATE_VERSION &&
  (value.role === "host" || value.role === "viewer" || value.role === "rejected") &&
  typeof value.generation === "string" &&
  Number.isSafeInteger(value.nextSequence) &&
  Number.isSafeInteger(value.lastActivityAt) &&
  Number.isSafeInteger(value.rateWindowStartedAt) &&
  Number.isSafeInteger(value.rateCount) &&
  typeof value.departed === "boolean";

const socketAttachment = (socket) => {
  try {
    const value = socket.deserializeAttachment();
    return validAttachment(value) ? value : undefined;
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

export class RendezvousSession extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
    this.env = env;
    this.invitation = null;
    this.corruptState = false;
    this.joinQueue = Promise.resolve();
    this.initialized = ctx.blockConcurrencyWhile(async () => {
      const stored = await ctx.storage.get(STORAGE_KEY);
      if (stored === undefined) return;
      if (!validInvitation(stored)) {
        this.corruptState = true;
        return;
      }
      this.invitation = stored;
    });
  }

  fetch(request) {
    const operation = this.joinQueue.then(() => this.handleJoin(request));
    this.joinQueue = operation.then(
      () => undefined,
      () => undefined,
    );
    return operation;
  }

  async handleJoin(request) {
    await this.initialized;
    if (this.corruptState) return json({ error: "service_unavailable" }, 503);

    const url = new URL(request.url);
    if (
      request.method !== "GET" ||
      url.pathname !== "/v1/rendezvous" ||
      url.search !== "" ||
      request.headers.get("Upgrade")?.toLowerCase() !== "websocket"
    ) {
      return json({ error: "invalid_join" }, 400);
    }
    const join = validateJoinHeaders(request.headers);
    if (join.error) return json({ error: join.error }, 400);
    const { channel, role, admission, proofBytes } = join.value;
    const now = Date.now();

    if (this.invitation && !admissionProofsMatch(this.invitation.admissionProof, proofBytes)) {
      return json({ error: "invitation_unavailable" }, 404);
    }

    if (this.invitation && !this.invitation.consumed && now >= this.invitation.expiresAt) {
      const expiredGeneration = this.invitation.generation;
      await this.expireInvitation(expiredGeneration);
      if (role === "viewer") {
        return this.rejectWebSocket("invitation_expired", CLOSE.expired);
      }
    }

    if (!this.invitation) {
      if (role !== "host") {
        return this.rejectWebSocket("invitation_unavailable", CLOSE.unavailable);
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
      };
      await this.ctx.storage.put(STORAGE_KEY, this.invitation);
      await this.ctx.storage.setAlarm(this.invitation.expiresAt);
    }

    const invitation = this.invitation;
    if (invitation.channel !== channel) return json({ error: "invitation_unavailable" }, 404);

    const occupiedRole = this.roleSockets(role, invitation.generation, true).length > 0;
    if (occupiedRole) return this.rejectWebSocket("role_already_claimed", CLOSE.conflict);

    const oppositeRole = role === "host" ? "viewer" : "host";
    let opposite = this.firstOpenRoleSocket(oppositeRole, invitation.generation);
    if (role === "viewer") {
      if (!opposite) return this.rejectWebSocket("invitation_unavailable", CLOSE.unavailable);
      if (invitation.consumed) {
        return this.rejectWebSocket("role_already_claimed", CLOSE.conflict);
      }
    } else if (invitation.consumed && !opposite) {
      return this.rejectWebSocket("role_already_claimed", CLOSE.conflict);
    }

    let iceServers;
    if (opposite) {
      try {
        iceServers = await iceServersForJoin(this.env);
      } catch (error) {
        if (error instanceof TurnProvisioningError) {
          return this.rejectWebSocket("turn_unavailable", CLOSE.retry);
        }
        return this.rejectWebSocket("service_unavailable", CLOSE.retry);
      }

      if (this.invitation !== invitation || this.invitation.generation !== invitation.generation) {
        return this.rejectWebSocket("invitation_unavailable", CLOSE.unavailable);
      }
      opposite = this.firstOpenRoleSocket(oppositeRole, invitation.generation);
      if (!opposite || this.roleSockets(role, invitation.generation, true).length > 0) {
        return this.rejectWebSocket(
          opposite ? "role_already_claimed" : "invitation_unavailable",
          opposite ? CLOSE.conflict : CLOSE.unavailable,
        );
      }
    }

    if (role === "viewer") {
      invitation.consumed = true;
      invitation.retireAt = null;
      await this.ctx.storage.put(STORAGE_KEY, invitation);
    }

    const accepted = this.acceptWebSocket(role, invitation.generation);
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

  acceptWebSocket(role, generation) {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment(newAttachment(role, generation, Date.now()));
    return {
      server,
      response: new Response(null, {
        status: 101,
        webSocket: client,
        headers: { "Cache-Control": "no-store" },
      }),
    };
  }

  rejectWebSocket(error, closeReason) {
    const generation = this.invitation?.generation ?? "rejected";
    const accepted = this.acceptWebSocket("rejected", generation);
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

  webSocketMessage(socket, message) {
    const attachment = socketAttachment(socket);
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

  async webSocketClose(socket) {
    await this.handleDeparture(socket);
  }

  async webSocketError(socket) {
    await this.handleDeparture(socket);
  }

  async handleDeparture(socket) {
    const attachment = socketAttachment(socket);
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
    if (url.pathname !== "/v1/rendezvous") return json({ error: "not_found" }, 404);
    if (
      request.method !== "GET" ||
      url.search !== "" ||
      url.protocol !== "https:" ||
      request.headers.get("Upgrade")?.toLowerCase() !== "websocket"
    ) {
      return json({ error: "invalid_join" }, 400);
    }

    const join = validateJoinHeaders(request.headers);
    if (join.error) return json({ error: join.error }, 400);
    const { channel, role, admission } = join.value;
    const actor = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const [actorLimit, channelLimit] = await Promise.all([
      env.JOIN_RATE_LIMITER.limit({ key: `actor:${actor}` }),
      env.JOIN_RATE_LIMITER.limit({ key: `channel:${channel}` }),
    ]);
    if (!actorLimit.success || !channelLimit.success) {
      return json({ error: "rate_limited" }, 429, { "Retry-After": "60" });
    }
    const id = env.RENDEZVOUS.idFromName(channel);
    const stub = env.RENDEZVOUS.get(id);
    const headers = new Headers({
      Upgrade: "websocket",
      [HEADER.channel]: channel,
      [HEADER.role]: role,
      [HEADER.admission]: admission,
    });
    return stub.fetch(new Request("https://rendezvous.internal/v1/rendezvous", { headers }));
  },
};
