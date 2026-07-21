import { DurableObject } from "cloudflare:workers";
import { TurnProvisioningError, iceServersForJoin } from "./ice.js";
import {
  AVAILABILITY_WEBSOCKET_PROTOCOL,
  HEADER,
  LIMITS,
  PAIRING_WEBSOCKET_PROTOCOL,
  admissionProofsMatch,
  inspectAvailabilityProbe,
  validateAvailabilitySignal,
  validateJoinHeaders,
  validateSignal,
} from "./protocol.js";

// Each channel maps to a Durable Object so invitation consumption, socket ownership, sequencing,
// and hibernation recovery have one serialized source of truth. Media never traverses this Worker.
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
  (value.viewerAckForwarded === undefined ||
    typeof value.viewerAckForwarded === "boolean") &&
  (value.pairingAttemptID === undefined ||
    value.pairingAttemptID === null ||
    typeof value.pairingAttemptID === "string") &&
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
  (value.pairingAttemptID === undefined ||
    value.pairingAttemptID === null ||
    typeof value.pairingAttemptID === "string") &&
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
  (value.connectionID === undefined || typeof value.connectionID === "string") &&
  typeof value.departed === "boolean";

const socketAttachment = (socket) => {
  try {
    const value = socket.deserializeAttachment();
    return validAvailabilityAttachment(value) || validAttachment(value) ? value : undefined;
  } catch {
    return undefined;
  }
};

const newAttachment = (role, generation, now, pairingAttemptID = null) => ({
  version: STATE_VERSION,
  role,
  generation,
  nextSequence: 0,
  lastActivityAt: now,
  rateWindowStartedAt: now,
  rateCount: 0,
  pairingAttemptID,
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
  connectionID: crypto.randomUUID(),
  departed: false,
});

const randomExchangeID = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
};

/**
 * Owns one invitation/pairing channel or one durable paired-device availability channel.
 * All state-changing entry points are serialized because WebSocket and alarm callbacks may arrive
 * concurrently around Durable Object hibernation boundaries.
 */
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

  /** Appends a mutation to a queue that remains usable even when the previous operation rejects. */
  serializeMutation(operation) {
    const result = this.mutationQueue.then(operation);
    this.mutationQueue = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  /** Validates and admits a WebSocket into the invitation or availability state machine. */
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
        ...(mode === "pairing"
          ? {
              mode: "pairing",
              viewerAckForwarded: false,
              pairingAttemptID: null,
            }
          : {}),
      };
      await this.ctx.storage.put(STORAGE_KEY, this.invitation);
      await this.ctx.storage.setAlarm(this.invitation.expiresAt);
    }

    let invitation = this.invitation;
    if (invitation.channel !== channel) return json({ error: "invitation_unavailable" }, 404);
    if ((invitation.mode ?? "invitation") !== mode) {
      return json({ error: "invitation_unavailable" }, 404);
    }

    // A closed hibernating socket can disappear from the occupied-role query before its
    // deferred close callback runs. Reconcile it inside the serialized join mutation so the
    // surviving peer observes reset/peer-left before any replacement ready event.
    await this.reconcileClosedInvitationRoleSockets(role, invitation.generation);
    if (!this.invitation || this.invitation.generation !== invitation.generation) {
      return this.rejectWebSocket("invitation_unavailable", CLOSE.unavailable, mode);
    }
    invitation = this.invitation;

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

    let pairingAttemptID = null;
    if (mode === "pairing" && opposite) {
      const previousAttemptID = invitation.pairingAttemptID ?? null;
      pairingAttemptID = crypto.randomUUID();
      invitation = {
        ...invitation,
        viewerAckForwarded: false,
        pairingAttemptID,
      };
      await this.ctx.storage.put(STORAGE_KEY, invitation);
      this.invitation = invitation;

      const oppositeAttachment = socketAttachment(opposite);
      if (
        !oppositeAttachment ||
        oppositeAttachment.role !== oppositeRole ||
        oppositeAttachment.generation !== invitation.generation
      ) {
        return this.rejectWebSocket("invitation_unavailable", CLOSE.unavailable, mode);
      }
      oppositeAttachment.nextSequence = 0;
      oppositeAttachment.pairingAttemptID = pairingAttemptID;
      oppositeAttachment.lastActivityAt = Date.now();
      opposite.serializeAttachment(oppositeAttachment);
      if (previousAttemptID !== null) {
        // A stale role socket disappeared before its close callback reset the survivor. Bind
        // the survivor to the replacement attempt and order peer-left before ready. The old
        // callback carries its prior attempt ID and cannot disturb this new transcript.
        safeSend(opposite, { type: "peer-left", role });
      }
    }

    // Legacy invitations authorize a media session directly, so accepting the viewer is
    // still the irreversible consume-once boundary. Pairing bootstrap is different: both
    // devices must first persist their recoverable pair root. Its invitation is consumed
    // below only when the host transmits completion after validating that acknowledgement.
    if (role === "viewer" && mode !== "pairing") {
      invitation.consumed = true;
      invitation.retireAt = null;
      await this.ctx.storage.put(STORAGE_KEY, invitation);
    }

    const accepted = this.acceptWebSocket(
      role,
      invitation.generation,
      mode,
      pairingAttemptID,
    );
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

    // Stable, pair-scoped proofs make a duplicate role a capability-authorized replacement.
    // Snapshot an open opposite socket first, then synchronously fence only the superseded same-role
    // sockets before installing the replacement. Joins are serialized, and there are no awaits
    // below this point, so the opposite attachment and replacement attachment move to one fresh
    // exchange as one mutation. Delayed callbacks remain fenced by `departed` and the old
    // exchange ID.
    const oppositeRole = role === "host" ? "viewer" : "host";
    const sameRoleSockets = this.attachedAvailabilityRoleSockets(
      role,
      availability.generation,
    );
    let opposite = this.firstOpenAvailabilityRoleSocket(
      oppositeRole,
      availability.generation,
    );
    let oppositeAttachment = opposite ? socketAttachment(opposite) : undefined;
    if (
      !oppositeAttachment ||
      oppositeAttachment.mode !== "availability" ||
      oppositeAttachment.role !== oppositeRole ||
      oppositeAttachment.generation !== availability.generation
    ) {
      opposite = undefined;
      oppositeAttachment = undefined;
    }

    // A viewer retry can indicate an exchange that no longer reaches the iPhone application.
    // A still-paired host may be an OPEN edge socket whose Mac application is not processing DO messages, so
    // rebinding it would reproduce the same timeout forever. Retire the superseded viewer
    // terminally, but notify/close the host transiently so it registers a fresh socket; this
    // viewer attempt receives unavailable and its bounded outer retry pairs after that host join.
    const replacesViewerExchange =
      role === "viewer" &&
      (sameRoleSockets.length > 0 || typeof oppositeAttachment?.exchangeID === "string");
    if (replacesViewerExchange) {
      this.retireAvailabilityRoleSocketsForReplacement(role, availability.generation);
      this.retireAvailabilityRoleSocketsForReplacement(
        "host",
        availability.generation,
        "peer_unavailable",
        CLOSE.retry,
      );
      return this.rejectAvailabilityWebSocket(
        "availability_unavailable",
        CLOSE.availabilityUnavailable,
      );
    }

    this.retireAvailabilityRoleSocketsForReplacement(role, availability.generation);

    if (!opposite) {
      if (role === "host") {
        const accepted = this.acceptAvailabilityWebSocket(
          "host",
          availability.generation,
          null,
        );
        safeSend(accepted.server, { type: "availability-waiting" });
        return accepted.response;
      }
      return this.rejectAvailabilityWebSocket(
        "availability_unavailable",
        CLOSE.availabilityUnavailable,
      );
    }

    const exchangeID = randomExchangeID();
    oppositeAttachment.exchangeID = exchangeID;
    oppositeAttachment.nextSequence = 0;
    oppositeAttachment.lastActivityAt = now;
    try {
      opposite.serializeAttachment(oppositeAttachment);
    } catch {
      this.retireAvailabilityRoleSocketsForReplacement(
        oppositeRole,
        availability.generation,
        "peer_unavailable",
        CLOSE.retry,
      );
      if (role === "host") {
        const accepted = this.acceptAvailabilityWebSocket(
          "host",
          availability.generation,
          null,
        );
        safeSend(accepted.server, { type: "availability-waiting" });
        return accepted.response;
      }
      return this.rejectAvailabilityWebSocket(
        "availability_unavailable",
        CLOSE.availabilityUnavailable,
      );
    }

    const accepted = this.acceptAvailabilityWebSocket(
      role,
      availability.generation,
      exchangeID,
    );
    // A fresh ready event itself is the exchange-reset boundary. Do not precede it with
    // peer-left: the persistent client intentionally treats peer-left as an outer-attempt
    // failure, while its ready parser safely replaces the exchange cipher and sequence state.
    const oppositeReady = safeSend(opposite, {
      type: "availability-ready",
      role: oppositeRole,
      exchangeID,
    });
    const replacementReady = safeSend(accepted.server, {
      type: "availability-ready",
      role,
      exchangeID,
    });
    if (!oppositeReady || !replacementReady) {
      if (oppositeRole === "host") {
        oppositeAttachment.exchangeID = null;
        oppositeAttachment.nextSequence = 0;
        oppositeAttachment.lastActivityAt = Date.now();
        try {
          opposite.serializeAttachment(oppositeAttachment);
        } catch {
          // A failed ready send can coincide with the host disconnecting.
        }
        safeClose(accepted.server, CLOSE.retry);
        if (oppositeReady) {
          safeSend(opposite, { type: "availability-waiting" });
        } else {
          safeClose(opposite, CLOSE.retry);
        }
      } else {
        const replacementAttachment = socketAttachment(accepted.server);
        if (replacementAttachment?.mode === "availability") {
          replacementAttachment.exchangeID = null;
          replacementAttachment.nextSequence = 0;
          replacementAttachment.lastActivityAt = Date.now();
          try {
            accepted.server.serializeAttachment(replacementAttachment);
          } catch {
            // A concurrent replacement close already prevents a waiting host transition.
          }
        }
        this.retireAvailabilityRoleSocketsForReplacement(
          "viewer",
          availability.generation,
          "peer_unavailable",
          CLOSE.retry,
        );
        if (replacementReady) {
          safeSend(accepted.server, { type: "availability-waiting" });
        } else {
          safeClose(accepted.server, CLOSE.retry);
        }
      }
    }
    return accepted.response;
  }

  acceptWebSocket(
    role,
    generation,
    mode = "invitation",
    pairingAttemptID = null,
  ) {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment(
      newAttachment(role, generation, Date.now(), pairingAttemptID),
    );
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

  attachedAvailabilityRoleSockets(role, generation) {
    return this.ctx.getWebSockets(role).filter((socket) => {
      const attachment = socketAttachment(socket);
      return (
        attachment?.mode === "availability" &&
        attachment.role === role &&
        attachment.generation === generation &&
        !attachment.departed
      );
    });
  }

  retireAvailabilityRoleSocketsForReplacement(
    role,
    generation,
    error = "role_already_claimed",
    closeReason = CLOSE.conflict,
  ) {
    const entries = this.attachedAvailabilityRoleSockets(role, generation).map((socket) => ({
      socket,
      attachment: socketAttachment(socket),
    }));
    const now = Date.now();

    // Serialize the superseded state before emitting the replacement/recovery error or closing.
    // The old exchange ID stays attached so even a copied/delayed callback cannot target a peer
    // that has already been rebound or has registered a fresh socket.
    for (const { socket, attachment } of entries) {
      if (!attachment) continue;
      attachment.departed = true;
      attachment.lastActivityAt = now;
      try {
        socket.serializeAttachment(attachment);
      } catch {
        // A fully detached socket is already retired from the live exchange.
      }
    }

    for (const { socket, attachment } of entries) {
      if (!attachment) continue;
      safeSend(socket, { type: "error", error });
      safeClose(socket, closeReason);
    }
  }

  async webSocketMessage(socket, message) {
    const attachment = socketAttachment(socket);
    if (attachment?.mode === "availability") {
      this.handleAvailabilityMessage(socket, message, attachment);
      return;
    }

    // Serialize invitation messages with joins and departures. In particular, a replacement
    // join must not race the host-confirmed consume transition below.
    await this.serializeMutation(() => this.handleInvitationMessage(socket, message));
  }

  async handleInvitationMessage(socket, message) {
    const attachment = socketAttachment(socket);
    const invitation = this.invitation;
    if (
      !attachment ||
      attachment.departed ||
      (attachment.role !== "host" && attachment.role !== "viewer") ||
      !invitation ||
      attachment.generation !== invitation.generation
    ) {
      safeClose(socket, CLOSE.invalid);
      return;
    }
    if (
      invitation.mode === "pairing" &&
      (typeof invitation.pairingAttemptID !== "string" ||
        attachment.pairingAttemptID !== invitation.pairingAttemptID)
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

    if (
      invitation.mode === "pairing" &&
      !invitation.consumed &&
      attachment.role === "viewer" &&
      result.value.seq === 2
    ) {
      const host = this.firstOpenRoleSocket("host", invitation.generation);
      const hostAttachment = host ? socketAttachment(host) : undefined;
      if (!host || !hostAttachment || hostAttachment.nextSequence < 3) {
        // Cross-direction sequencing is visible even though ciphertext is not. Refuse a viewer
        // ACK position until the host proposal position was forwarded.
        safeSend(socket, { type: "error", error: "invalid_message" });
        safeClose(socket, CLOSE.invalid);
        return;
      }
    }

    if (
      invitation.mode === "pairing" &&
      attachment.role === "host" &&
      result.value.seq === 3 &&
      !invitation.consumed
    ) {
      if (invitation.viewerAckForwarded !== true) {
        // Host completion is authoritative only after this same invitation generation
        // durably recorded successful forwarding of the viewer ACK position.
        safeSend(socket, { type: "error", error: "invalid_message" });
        safeClose(socket, CLOSE.invalid);
        return;
      }
      // Host sequence 3 is the completion sent only after the Mac has decrypted and
      // authenticated the viewer ACK, then durably saved its accepted/completion state. The
      // Worker cannot authenticate opaque viewer ciphertext, so viewer sequence 2 alone must
      // never consume an invitation. Persist the tombstone before forwarding the host's
      // completion: after this point the Mac and iPhone both have recoverable pairing records.
      const consumedInvitation = {
        ...invitation,
        consumed: true,
        retireAt: null,
      };
      await this.ctx.storage.put(STORAGE_KEY, consumedInvitation);
      this.invitation = consumedInvitation;
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

    const recordsViewerAckProgress =
      invitation.mode === "pairing" &&
      attachment.role === "viewer" &&
      result.value.seq === 2 &&
      !invitation.consumed;

    // Advance the hibernation attachment before the separate progress write. If persistence
    // fails or the actor is evicted between them, the host-confirmed consume step fails closed
    // and both authenticated peers can continue on availability; the viewer sequence cannot
    // be rolled back after progress was durably recorded.
    attachment.nextSequence += 1;
    socket.serializeAttachment(attachment);

    if (recordsViewerAckProgress) {
      // This is routing evidence, not authentication: the Worker still cannot inspect the
      // ciphertext. Persist it only after the ACK position was successfully forwarded so a
      // hibernation/restart cannot turn host-only sequence 3 into a consume boundary.
      const progressedInvitation = {
        ...invitation,
        viewerAckForwarded: true,
      };
      await this.ctx.storage.put(STORAGE_KEY, progressedInvitation);
      this.invitation = progressedInvitation;
    }
  }

  handleAvailabilityMessage(socket, message, attachment) {
    const availability = this.availability;
    const probe = inspectAvailabilityProbe(message);
    if (probe.matched) {
      this.handleAvailabilityProbe(socket, attachment, availability, probe);
      return;
    }
    if (
      attachment.departed ||
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

  handleAvailabilityProbe(socket, attachment, availability, probe) {
    const currentHost = availability
      ? this.firstOpenAvailabilityRoleSocket("host", availability.generation)
      : undefined;
    const currentHostAttachment = currentHost ? socketAttachment(currentHost) : undefined;
    const isAuthorizedHost =
      !attachment.departed &&
      attachment.role === "host" &&
      availability !== null &&
      attachment.generation === availability.generation &&
      typeof attachment.connectionID === "string" &&
      currentHostAttachment?.connectionID === attachment.connectionID;
    if (!isAuthorizedHost) {
      // Preserve the existing observable policy for a capability-authorized viewer sending a
      // message outside its role. Stale, departed, rejected, or otherwise non-current sockets
      // receive no oracle response; they are simply closed before any attachment can be mutated.
      if (
        !attachment.departed &&
        attachment.role === "viewer" &&
        availability !== null &&
        attachment.generation === availability.generation
      ) {
        safeSend(socket, { type: "error", error: "invalid_message" });
      }
      safeClose(socket, CLOSE.invalid);
      return;
    }
    if (probe.error) {
      safeSend(socket, { type: "error", error: probe.error });
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

    if (!safeSend(socket, { type: "availability-probe-ack", nonce: probe.value.nonce })) {
      safeClose(socket, CLOSE.retry);
    }
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

    let invitation = this.invitation;
    if (!invitation || attachment.generation !== invitation.generation) return;
    if (
      invitation.mode === "pairing" &&
      (attachment.pairingAttemptID ?? null) !==
        (invitation.pairingAttemptID ?? null)
    ) {
      // The current pairing attempt replaced this socket before its close callback ran.
      // Never let a stale callback reset the live attempt's progress or survivor sequence.
      return;
    }
    if (
      invitation.mode === "pairing" &&
      !invitation.consumed &&
      (invitation.pairingAttemptID ?? null) !== null
    ) {
      invitation = {
        ...invitation,
        viewerAckForwarded: false,
        pairingAttemptID: null,
      };
      await this.ctx.storage.put(STORAGE_KEY, invitation);
      this.invitation = invitation;
    }
    const oppositeRole = attachment.role === "host" ? "viewer" : "host";
    const partner = this.firstOpenRoleSocket(oppositeRole, invitation.generation);
    if (partner && invitation.mode === "pairing" && !invitation.consumed) {
      const partnerAttachment = socketAttachment(partner);
      if (
        partnerAttachment &&
        partnerAttachment.role === oppositeRole &&
        partnerAttachment.generation === invitation.generation
      ) {
        // A pre-ACK pairing attempt is recoverably incomplete, not consumed. Let the live
        // partner start a replacement exchange at the protocol's canonical first sequence.
        partnerAttachment.nextSequence = 0;
        partnerAttachment.pairingAttemptID = null;
        partnerAttachment.lastActivityAt = Date.now();
        try {
          partner.serializeAttachment(partnerAttachment);
        } catch {
          // A concurrent partner close already prevents a replacement exchange on this socket.
        }
      }
    }
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

  async reconcileClosedInvitationRoleSockets(role, generation) {
    const closedSockets = this.ctx.getWebSockets(role).filter((socket) => {
      const attachment = socketAttachment(socket);
      return (
        attachment?.role === role &&
        attachment.generation === generation &&
        !attachment.departed &&
        socket.readyState === CLOSED
      );
    });
    for (const socket of closedSockets) {
      await this.handleDeparture(socket);
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
  /**
   * Public Worker router: validates the outer request, rate-limits actor and channel dimensions,
   * then forwards a minimal canonical request to the channel's Durable Object.
   */
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
