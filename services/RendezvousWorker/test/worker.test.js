import { env, evictDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";

const base64URL = (bytes) =>
  btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");

const proof = (fill) => base64URL(new Uint8Array(32).fill(fill));
const joinHeaders = (channel, role, admission) => ({
  Upgrade: "websocket",
  "X-AudioStreamer-Channel": channel,
  "X-AudioStreamer-Role": role,
  "X-AudioStreamer-Admission": admission,
});

const open = async (channel, role, admission) => {
  const response = await SELF.fetch("https://example.com/v1/rendezvous", {
    headers: joinHeaders(channel, role, admission),
  });
  expect(response.status).toBe(101);
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
});
