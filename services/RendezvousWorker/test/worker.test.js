import { env, evictDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";

const base64URL = (bytes) =>
  btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");

const proof = (fill) => base64URL(new Uint8Array(32).fill(fill));
const joinHeaders = (channel, role, admission, mode, viewerAdmission) => ({
  Upgrade: "websocket",
  "X-AudioStreamer-Channel": channel,
  "X-AudioStreamer-Role": role,
  "X-AudioStreamer-Admission": admission,
  ...(mode === "availability" ? { "X-AudioStreamer-Mode": mode } : {}),
  ...(mode === "availability"
    ? { "Sec-WebSocket-Protocol": "audiostreamer.availability.v1" }
    : mode === "pairing"
      ? { "Sec-WebSocket-Protocol": "audiostreamer.pairing.v1" }
    : {}),
  ...(viewerAdmission
    ? { "X-AudioStreamer-Viewer-Admission": viewerAdmission }
    : {}),
});

const open = async (channel, role, admission, mode, viewerAdmission) => {
  const path = mode === "availability" ? "/v2/availability" : "/v1/rendezvous";
  const response = await SELF.fetch(`https://example.com${path}`, {
    headers: joinHeaders(channel, role, admission, mode, viewerAdmission),
  });
  expect(response.status).toBe(101);
  expect(response.headers.get("Sec-WebSocket-Protocol")).toBe(
    mode === "availability"
      ? "audiostreamer.availability.v1"
      : mode === "pairing"
        ? "audiostreamer.pairing.v1"
        : null,
  );
  const socket = response.webSocket;
  const queued = [];
  const waiters = [];
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    const waiter = waiters.shift();
    if (waiter) waiter(message);
    else queued.push(message);
  });
  socket.accept();
  return {
    socket,
    nextMessage: () => {
      if (queued.length > 0) return Promise.resolve(queued.shift());
      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error("timed out waiting for message")), 1_000);
        waiters.push((message) => {
          clearTimeout(timeout);
          resolve(message);
        });
      });
    },
  };
};

const signalEnvelope = (channel, sequence, role) => {
  const inner = {
    version: 1,
    channelID: channel,
    direction: role === "host" ? "hostToViewer" : "viewerToHost",
    sequence,
    ciphertext: btoa("sealed ciphertext"),
  };
  return base64URL(new TextEncoder().encode(JSON.stringify(inner)));
};

const availabilityEnvelope = (channel, exchangeID, sequence, role) => {
  const inner = {
    version: 1,
    channelID: channel,
    exchangeID,
    direction: role === "host" ? "hostToViewer" : "viewerToHost",
    sequence,
    ciphertext: btoa("opaque pairing exchange"),
  };
  return base64URL(new TextEncoder().encode(JSON.stringify(inner)));
};

describe("rendezvous Worker and Durable Object", () => {
  it("serves a secret-free health response and rejects query joins", async () => {
    const health = await SELF.fetch("https://example.com/healthz");
    expect(health.status).toBe(200);
    expect(await health.json()).toEqual({ ok: true });

    const channel = "Q".repeat(52);
    const response = await SELF.fetch("https://example.com/v1/rendezvous?channel=forbidden", {
      headers: joinHeaders(channel, "host", proof(1)),
    });
    expect(response.status).toBe(400);

    const downgradedAvailability = await SELF.fetch("https://example.com/v1/rendezvous", {
      headers: joinHeaders(channel, "host", proof(1), "availability", proof(2)),
    });
    expect(downgradedAvailability.status).toBe(400);

    const unknownProtocolHeaders = new Headers(
      joinHeaders(channel, "host", proof(1), "availability", proof(2)),
    );
    unknownProtocolHeaders.set("Sec-WebSocket-Protocol", "unknown.availability");
    const unknownProtocol = await SELF.fetch("https://example.com/v2/availability", {
      headers: unknownProtocolHeaders,
    });
    expect(unknownProtocol.status).toBe(400);

    unknownProtocolHeaders.delete("Sec-WebSocket-Protocol");
    const missingProtocol = await SELF.fetch("https://example.com/v2/availability", {
      headers: unknownProtocolHeaders,
    });
    expect(missingProtocol.status).toBe(400);
  });

  it("rejects viewer-before-host without consuming persistent availability", async () => {
    const channel = "V".repeat(52);
    const hostProof = proof(31);
    const viewerProof = proof(32);
    const earlyViewer = await open(channel, "viewer", viewerProof, "availability");
    expect(await earlyViewer.nextMessage()).toEqual({
      type: "error",
      error: "availability_unavailable",
    });
    earlyViewer.socket.close(1000, "done");

    const host = await open(channel, "host", hostProof, "availability", viewerProof);
    expect(await host.nextMessage()).toEqual({ type: "availability-waiting" });
    const viewer = await open(channel, "viewer", viewerProof, "availability");
    const [hostReady, viewerReady] = await Promise.all([
      host.nextMessage(),
      viewer.nextMessage(),
    ]);
    expect(hostReady.exchangeID).toBe(viewerReady.exchangeID);
    host.socket.close(1000, "done");
    viewer.socket.close(1000, "done");
  });

  it("isolates negotiated pairing bootstrap from legacy invitation clients", async () => {
    const channel = "P".repeat(52);
    const admission = proof(33);
    const pairingHost = await open(channel, "host", admission, "pairing");
    expect((await pairingHost.nextMessage()).type).toBe("waiting");

    const legacyViewer = await open(channel, "viewer", admission);
    expect(await legacyViewer.nextMessage()).toEqual({
      type: "error",
      error: "invitation_unavailable",
    });
    legacyViewer.socket.close(1000, "done");

    const pairingViewer = await open(channel, "viewer", admission, "pairing");
    const [hostReady, viewerReady] = await Promise.all([
      pairingHost.nextMessage(),
      pairingViewer.nextMessage(),
    ]);
    expect(hostReady.type).toBe("ready");
    expect(viewerReady.type).toBe("ready");
    expect(hostReady.iceServers).toEqual([]);
    expect(viewerReady.iceServers).toEqual([]);
    pairingHost.socket.close(1000, "done");
    pairingViewer.socket.close(1000, "done");
  });

  it("restarts an unconsumed pairing from sequence zero after a partial viewer departs", async () => {
    const channel = "R".repeat(52);
    const admission = proof(34);
    const host = await open(channel, "host", admission, "pairing");
    expect((await host.nextMessage()).type).toBe("waiting");

    const firstViewer = await open(channel, "viewer", admission, "pairing");
    await Promise.all([host.nextMessage(), firstViewer.nextMessage()]);

    for (let sequence = 0; sequence < 2; sequence += 1) {
      const hostEnvelope = signalEnvelope(channel, sequence, "host");
      host.socket.send(
        JSON.stringify({ type: "signal", seq: sequence, envelope: hostEnvelope }),
      );
      expect(await firstViewer.nextMessage()).toEqual({
        type: "signal",
        from: "host",
        seq: sequence,
        envelope: hostEnvelope,
      });

      const viewerEnvelope = signalEnvelope(channel, sequence, "viewer");
      firstViewer.socket.send(
        JSON.stringify({ type: "signal", seq: sequence, envelope: viewerEnvelope }),
      );
      expect(await host.nextMessage()).toEqual({
        type: "signal",
        from: "viewer",
        seq: sequence,
        envelope: viewerEnvelope,
      });
    }

    const firstViewerLeft = host.nextMessage();
    firstViewer.socket.close(1000, "interrupted before durable ACK");
    expect(await firstViewerLeft).toEqual({ type: "peer-left", role: "viewer" });

    const replacementViewer = await open(channel, "viewer", admission, "pairing");
    const [hostReady, replacementReady] = await Promise.all([
      host.nextMessage(),
      replacementViewer.nextMessage(),
    ]);
    expect(hostReady.type).toBe("ready");
    expect(replacementReady.type).toBe("ready");

    // The surviving host had already sent sequences 0 and 1. Reaccepting sequence 0 proves
    // its hibernation attachment was reset for the replacement pairing exchange.
    const restartedHostEnvelope = signalEnvelope(channel, 0, "host");
    host.socket.send(
      JSON.stringify({ type: "signal", seq: 0, envelope: restartedHostEnvelope }),
    );
    expect(await replacementViewer.nextMessage()).toEqual({
      type: "signal",
      from: "host",
      seq: 0,
      envelope: restartedHostEnvelope,
    });

    const restartedViewerEnvelope = signalEnvelope(channel, 0, "viewer");
    replacementViewer.socket.send(
      JSON.stringify({ type: "signal", seq: 0, envelope: restartedViewerEnvelope }),
    );
    expect(await host.nextMessage()).toEqual({
      type: "signal",
      from: "viewer",
      seq: 0,
      envelope: restartedViewerEnvelope,
    });

    host.socket.close(1000, "done");
    replacementViewer.socket.close(1000, "done");
  });

  it("durably consumes pairing at the viewer sequence-2 ACK and rejects replacement", async () => {
    const channel = "K".repeat(52);
    const admission = proof(35);
    const host = await open(channel, "host", admission, "pairing");
    await host.nextMessage();
    const viewer = await open(channel, "viewer", admission, "pairing");
    await Promise.all([host.nextMessage(), viewer.nextMessage()]);

    for (let sequence = 0; sequence <= 2; sequence += 1) {
      const envelope = signalEnvelope(channel, sequence, "viewer");
      viewer.socket.send(JSON.stringify({ type: "signal", seq: sequence, envelope }));
      expect(await host.nextMessage()).toEqual({
        type: "signal",
        from: "viewer",
        seq: sequence,
        envelope,
      });
    }

    // Force a new object instance so replacement rejection depends on the stored consume
    // boundary, not merely the in-memory invitation object.
    const stub = env.RENDEZVOUS.get(env.RENDEZVOUS.idFromName(`pairing:${channel}`));
    await evictDurableObject(stub);

    const viewerLeft = host.nextMessage();
    viewer.socket.close(1000, "done");
    expect(await viewerLeft).toEqual({ type: "peer-left", role: "viewer" });

    const replacement = await open(channel, "viewer", admission, "pairing");
    expect(await replacement.nextMessage()).toEqual({
      type: "error",
      error: "role_already_claimed",
    });

    host.socket.close(1000, "done");
    replacement.socket.close(1000, "done");
  });

  it("requires host-first proof and does not consume on a mismatched viewer", async () => {
    const channel = "H".repeat(52);
    const hostProof = proof(2);
    const host = await open(channel, "host", hostProof);
    expect((await host.nextMessage()).type).toBe("waiting");

    const mismatch = await SELF.fetch("https://example.com/v1/rendezvous", {
      headers: joinHeaders(channel, "viewer", proof(3)),
    });
    expect(mismatch.status).toBe(404);

    const viewer = await open(channel, "viewer", hostProof);
    expect((await host.nextMessage()).type).toBe("ready");
    const viewerReady = await viewer.nextMessage();
    expect(viewerReady.type).toBe("ready");
    expect(viewerReady.iceServers).toEqual([
      { urls: ["stun:stun.cloudflare.com:3478"] },
    ]);
    host.socket.close(1000, "done");
    viewer.socket.close(1000, "done");
  });

  it("preserves sequence attachments through hibernation and retains a consume-once tombstone", async () => {
    const channel = "S".repeat(52);
    const admission = proof(4);
    const logSpies = ["log", "info", "warn", "error"].map((method) =>
      vi.spyOn(console, method).mockImplementation(() => {}),
    );
    const host = await open(channel, "host", admission);
    await host.nextMessage();
    const viewer = await open(channel, "viewer", admission);
    await Promise.all([host.nextMessage(), viewer.nextMessage()]);

    const stub = env.RENDEZVOUS.get(env.RENDEZVOUS.idFromName(channel));
    await evictDurableObject(stub);

    const envelope = signalEnvelope(channel, 0, "host");
    host.socket.send(JSON.stringify({ type: "signal", seq: 0, envelope }));
    expect(await viewer.nextMessage()).toEqual({
      type: "signal",
      from: "host",
      seq: 0,
      envelope,
    });

    const hostPeerLeft = host.nextMessage();
    viewer.socket.close(1000, "done");
    expect(await hostPeerLeft).toEqual({ type: "peer-left", role: "viewer" });

    const replacement = await open(channel, "viewer", admission);
    expect(await replacement.nextMessage()).toEqual({
      type: "error",
      error: "role_already_claimed",
    });
    host.socket.close(1000, "done");

    const logged = JSON.stringify(logSpies.flatMap((spy) => spy.mock.calls));
    expect(logged).not.toContain(channel);
    expect(logged).not.toContain(admission);
    expect(logged).not.toContain(envelope);
    for (const spy of logSpies) spy.mockRestore();
  });

  it("isolates persistent availability from invitations and proof-gates before occupancy", async () => {
    const channel = "A".repeat(52);
    const invitationProof = proof(5);
    const hostProof = proof(6);
    const viewerProof = proof(7);
    const invitationHost = await open(channel, "host", invitationProof);
    expect((await invitationHost.nextMessage()).type).toBe("waiting");

    const availabilityHost = await open(
      channel,
      "host",
      hostProof,
      "availability",
      viewerProof,
    );
    expect(await availabilityHost.nextMessage()).toEqual({ type: "availability-waiting" });

    const mismatch = await SELF.fetch("https://example.com/v2/availability", {
      headers: joinHeaders(channel, "viewer", proof(8), "availability"),
    });
    expect(mismatch.status).toBe(404);

    const swappedHostProof = await SELF.fetch("https://example.com/v2/availability", {
      headers: joinHeaders(channel, "viewer", hostProof, "availability"),
    });
    expect(swappedHostProof.status).toBe(404);

    const viewer = await open(channel, "viewer", viewerProof, "availability");
    const [hostReady, viewerReady] = await Promise.all([
      availabilityHost.nextMessage(),
      viewer.nextMessage(),
    ]);
    expect(hostReady).toEqual({
      type: "availability-ready",
      role: "host",
      exchangeID: viewerReady.exchangeID,
    });
    expect(viewerReady).toEqual({
      type: "availability-ready",
      role: "viewer",
      exchangeID: viewerReady.exchangeID,
    });
    expect(viewerReady.exchangeID).toMatch(/^[A-Za-z0-9_-]{22}$/);
    expect(viewerReady).not.toHaveProperty("iceServers");
    expect(viewerReady).not.toHaveProperty("invitationExpiresAt");

    invitationHost.socket.close(1000, "done");
    availabilityHost.socket.close(1000, "done");
    viewer.socket.close(1000, "done");
  });

  it("forwards only exchange-bound availability signals after hibernation", async () => {
    const channel = "B".repeat(52);
    const hostProof = proof(9);
    const viewerProof = proof(10);
    const host = await open(channel, "host", hostProof, "availability", viewerProof);
    await host.nextMessage();
    const viewer = await open(channel, "viewer", viewerProof, "availability");
    const [, ready] = await Promise.all([host.nextMessage(), viewer.nextMessage()]);

    const stub = env.RENDEZVOUS.get(env.RENDEZVOUS.idFromName(`availability:${channel}`));
    await evictDurableObject(stub);

    const envelope = availabilityEnvelope(channel, ready.exchangeID, 0, "host");
    host.socket.send(
      JSON.stringify({
        type: "availability-signal",
        exchangeID: ready.exchangeID,
        seq: 0,
        envelope,
      }),
    );
    expect(await viewer.nextMessage()).toEqual({
      type: "availability-signal",
      from: "host",
      exchangeID: ready.exchangeID,
      seq: 0,
      envelope,
    });

    host.socket.close(1000, "done");
    viewer.socket.close(1000, "done");
  });

  it("keeps the host available across serialized sequential viewer exchanges", async () => {
    const channel = "C".repeat(52);
    const hostProof = proof(11);
    const viewerProof = proof(12);
    const host = await open(channel, "host", hostProof, "availability", viewerProof);
    await host.nextMessage();
    const firstViewer = await open(channel, "viewer", viewerProof, "availability");
    const [, firstReady] = await Promise.all([host.nextMessage(), firstViewer.nextMessage()]);

    const peerLeft = host.nextMessage();
    firstViewer.socket.close(1000, "done");
    expect(await peerLeft).toEqual({
      type: "availability-peer-left",
      role: "viewer",
      exchangeID: firstReady.exchangeID,
    });
    expect(await host.nextMessage()).toEqual({ type: "availability-waiting" });

    const secondViewer = await open(channel, "viewer", viewerProof, "availability");
    const [secondHostReady, secondViewerReady] = await Promise.all([
      host.nextMessage(),
      secondViewer.nextMessage(),
    ]);
    expect(secondViewerReady.exchangeID).not.toBe(firstReady.exchangeID);
    expect(secondHostReady.exchangeID).toBe(secondViewerReady.exchangeID);

    const staleEnvelope = availabilityEnvelope(channel, firstReady.exchangeID, 0, "host");
    host.socket.send(
      JSON.stringify({
        type: "availability-signal",
        exchangeID: firstReady.exchangeID,
        seq: 0,
        envelope: staleEnvelope,
      }),
    );
    expect(await host.nextMessage()).toEqual({ type: "error", error: "invalid_exchange" });

    host.socket.close(1000, "done");
    secondViewer.socket.close(1000, "done");
  });

  it("retains both role-specific availability proofs across host reconnects", async () => {
    const channel = "D".repeat(52);
    const hostProof = proof(13);
    const viewerProof = proof(14);
    const host = await open(channel, "host", hostProof, "availability", viewerProof);
    await host.nextMessage();
    host.socket.close(1000, "done");

    const stub = env.RENDEZVOUS.get(env.RENDEZVOUS.idFromName(`availability:${channel}`));
    await evictDurableObject(stub);

    const mismatchedHost = await SELF.fetch("https://example.com/v2/availability", {
      headers: joinHeaders(channel, "host", proof(15), "availability", viewerProof),
    });
    expect(mismatchedHost.status).toBe(404);

    const changedViewerProof = await SELF.fetch("https://example.com/v2/availability", {
      headers: joinHeaders(channel, "host", hostProof, "availability", proof(16)),
    });
    expect(changedViewerProof.status).toBe(404);

    const replacementHost = await open(
      channel,
      "host",
      hostProof,
      "availability",
      viewerProof,
    );
    expect(await replacementHost.nextMessage()).toEqual({ type: "availability-waiting" });
    replacementHost.socket.close(1000, "done");
  });

  it("binds host departure to the old exchange before accepting a replacement host", async () => {
    const channel = "E".repeat(52);
    const hostProof = proof(17);
    const viewerProof = proof(18);
    const host = await open(channel, "host", hostProof, "availability", viewerProof);
    await host.nextMessage();
    const viewer = await open(channel, "viewer", viewerProof, "availability");
    const [, ready] = await Promise.all([host.nextMessage(), viewer.nextMessage()]);

    const hostLeft = viewer.nextMessage();
    host.socket.close(1000, "done");
    expect(await hostLeft).toEqual({
      type: "availability-peer-left",
      role: "host",
      exchangeID: ready.exchangeID,
    });

    const replacementHost = await open(
      channel,
      "host",
      hostProof,
      "availability",
      viewerProof,
    );
    expect(await replacementHost.nextMessage()).toEqual({ type: "availability-waiting" });
    const replacementViewer = await open(channel, "viewer", viewerProof, "availability");
    const [replacementHostReady, replacementViewerReady] = await Promise.all([
      replacementHost.nextMessage(),
      replacementViewer.nextMessage(),
    ]);
    expect(replacementHostReady.exchangeID).toBe(replacementViewerReady.exchangeID);
    expect(replacementViewerReady.exchangeID).not.toBe(ready.exchangeID);

    replacementHost.socket.close(1000, "done");
    replacementViewer.socket.close(1000, "done");
  });
});
