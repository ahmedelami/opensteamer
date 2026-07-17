import { describe, expect, it } from "vitest";
import {
  admissionProofsMatch,
  validateAvailabilitySignal,
  validateJoinHeaders,
  validateSignal,
} from "../src/protocol.js";

const base64URL = (bytes) =>
  btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");

const channel = "A".repeat(52);
const proof = base64URL(new Uint8Array(32).fill(0xa5));
const viewerProof = base64URL(new Uint8Array(32).fill(0xb6));

const sealedEnvelope = (sequence, overrides = {}) => {
  const envelope = {
    version: 1,
    channelID: channel,
    direction: "hostToViewer",
    sequence,
    ciphertext: btoa("sealed ciphertext"),
    ...overrides,
  };
  return base64URL(new TextEncoder().encode(JSON.stringify(envelope)));
};

const availabilityEnvelope = (exchangeID, sequence, overrides = {}) => {
  const envelope = {
    version: 1,
    channelID: channel,
    exchangeID,
    direction: "hostToViewer",
    sequence,
    ciphertext: btoa("opaque pairing exchange"),
    ...overrides,
  };
  return base64URL(new TextEncoder().encode(JSON.stringify(envelope)));
};

describe("upgrade and signaling validation", () => {
  it("accepts only bounded canonical join headers", () => {
    const headers = new Headers({
      "X-AudioStreamer-Channel": channel,
      "X-AudioStreamer-Role": "host",
      "X-AudioStreamer-Admission": proof,
    });
    const join = validateJoinHeaders(headers);
    expect(join.error).toBeUndefined();
    expect(admissionProofsMatch(proof, join.value.proofBytes)).toBe(true);

    headers.set("X-AudioStreamer-Admission", `${proof}=`);
    expect(validateJoinHeaders(headers)).toEqual({ error: "invalid_admission" });

    headers.set("X-AudioStreamer-Admission", proof);
    headers.set("X-AudioStreamer-Mode", "availability");
    expect(validateJoinHeaders(headers)).toEqual({ error: "invalid_mode" });

    headers.set("X-AudioStreamer-Viewer-Admission", viewerProof);
    headers.set("Sec-WebSocket-Protocol", "audiostreamer.availability.v1");
    expect(validateJoinHeaders(headers, "availability").value.mode).toBe("availability");

    headers.set("X-AudioStreamer-Mode", "Availability");
    expect(validateJoinHeaders(headers, "availability")).toEqual({ error: "invalid_mode" });

    headers.set("X-AudioStreamer-Mode", "availability");
    headers.set("Sec-WebSocket-Protocol", "wrong.protocol");
    expect(validateJoinHeaders(headers, "availability")).toEqual({
      error: "invalid_websocket_protocol",
    });
    headers.set("Sec-WebSocket-Protocol", "audiostreamer.availability.v1");
    headers.set("X-AudioStreamer-Role", "viewer");
    expect(validateJoinHeaders(headers, "availability")).toEqual({
      error: "invalid_viewer_admission",
    });
    headers.delete("X-AudioStreamer-Viewer-Admission");
    expect(validateJoinHeaders(headers, "availability").value.viewerAdmission).toBeNull();
  });

  it("selects pairing only through its exact v1 WebSocket subprotocol", () => {
    const headers = new Headers({
      "X-AudioStreamer-Channel": channel,
      "X-AudioStreamer-Role": "host",
      "X-AudioStreamer-Admission": proof,
      "Sec-WebSocket-Protocol": "audiostreamer.pairing.v1",
    });
    expect(validateJoinHeaders(headers, "invitation").value.mode).toBe("pairing");

    headers.set("Sec-WebSocket-Protocol", "audiostreamer.pairing.v2");
    expect(validateJoinHeaders(headers, "invitation")).toEqual({
      error: "invalid_websocket_protocol",
    });
  });

  it("requires exact outer and sealed-envelope schemas with monotonic sequence", () => {
    const options = { channel, role: "host", expectedSequence: 0 };
    const valid = JSON.stringify({ type: "signal", seq: 0, envelope: sealedEnvelope(0) });
    expect(validateSignal(valid, options).value).toEqual(JSON.parse(valid));

    expect(
      validateSignal(
        JSON.stringify({ type: "signal", seq: 1, envelope: sealedEnvelope(1) }),
        options,
      ).error,
    ).toBe("unexpected_sequence");
    expect(
      validateSignal(
        JSON.stringify({ type: "signal", seq: 0, envelope: sealedEnvelope(0), extra: true }),
        options,
      ).error,
    ).toBe("invalid_message");
    expect(
      validateSignal(
        JSON.stringify({
          type: "signal",
          seq: 0,
          envelope: sealedEnvelope(0, { direction: "viewerToHost" }),
        }),
        options,
      ).error,
    ).toBe("invalid_envelope");
  });

  it("binds availability ciphertexts to the server exchange ID", () => {
    const exchangeID = base64URL(new Uint8Array(16).fill(0x5c));
    const options = { channel, role: "host", exchangeID, expectedSequence: 0 };
    const valid = JSON.stringify({
      type: "availability-signal",
      exchangeID,
      seq: 0,
      envelope: availabilityEnvelope(exchangeID, 0),
    });
    expect(validateAvailabilitySignal(valid, options).value).toEqual(JSON.parse(valid));

    expect(
      validateAvailabilitySignal(
        JSON.stringify({
          type: "availability-signal",
          exchangeID: base64URL(new Uint8Array(16).fill(0x6d)),
          seq: 0,
          envelope: availabilityEnvelope(exchangeID, 0),
        }),
        options,
      ).error,
    ).toBe("invalid_exchange");
    expect(
      validateAvailabilitySignal(
        JSON.stringify({
          type: "availability-signal",
          exchangeID,
          seq: 0,
          envelope: availabilityEnvelope(exchangeID, 0, {
            exchangeID: base64URL(new Uint8Array(16).fill(0x6d)),
          }),
        }),
        options,
      ).error,
    ).toBe("invalid_envelope");
    expect(
      validateAvailabilitySignal(
        JSON.stringify({
          type: "availability-signal",
          exchangeID,
          seq: 0,
          envelope: availabilityEnvelope(exchangeID, 0),
          extra: true,
        }),
        options,
      ).error,
    ).toBe("invalid_message");
  });
});
