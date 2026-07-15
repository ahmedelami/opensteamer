import { describe, expect, it } from "vitest";
import { admissionProofsMatch, validateJoinHeaders, validateSignal } from "../src/protocol.js";

const base64URL = (bytes) =>
  btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");

const channel = "A".repeat(52);
const proof = base64URL(new Uint8Array(32).fill(0xa5));

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
});
