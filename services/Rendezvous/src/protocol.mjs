// The rendezvous service validates only routing metadata and opaque encrypted envelopes. It never
// receives the plaintext SDP/ICE signaling content carried inside those envelopes.
export const CHANNEL_PATTERN = /^[A-Za-z0-9_-]{22,128}$/;
// These former-brand header names are the deployed v1 compatibility ABI. Renaming the product
// must not change them without a separately versioned protocol migration.
export const CHANNEL_HEADER = "x-audiostreamer-channel";
export const ROLE_HEADER = "x-audiostreamer-role";
export const ADMISSION_PROOF_HEADER = "x-audiostreamer-admission";
const ADMISSION_PROOF_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const ENVELOPE_PATTERN = /^[A-Za-z0-9_-]+$/;

/** Decodes a canonical 256-bit base64url admission proof, or returns `undefined`. */
export function decodeAdmissionProof(value) {
  if (typeof value !== "string" || !ADMISSION_PROOF_PATTERN.test(value)) return undefined;
  const decoded = Buffer.from(value, "base64url");
  if (decoded.byteLength !== 32 || decoded.toString("base64url") !== value) return undefined;
  return decoded;
}

/** Validates the routing identity used during a WebSocket upgrade. */
export function validateJoin(channel, role) {
  if (typeof channel !== "string" || !CHANNEL_PATTERN.test(channel)) return "invalid_channel";
  if (role !== "host" && role !== "viewer") return "invalid_role";
  return undefined;
}

/**
 * Validates one sequenced, opaque signaling message before it is forwarded to the other peer.
 * The exact schema and monotonic sequence prevent extension-field smuggling and replay.
 */
export function validateSignal(raw, { expectedSequence, maxSequence, maxEnvelopeBytes }) {
  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    return { error: "invalid_json" };
  }
  if (!message || typeof message !== "object" || Array.isArray(message)) {
    return { error: "invalid_message" };
  }
  const keys = Object.keys(message).sort();
  if (keys.join(",") !== "envelope,seq,type" || message.type !== "signal") {
    return { error: "invalid_message" };
  }
  if (!Number.isSafeInteger(message.seq) || message.seq < 0 || message.seq > maxSequence) {
    return { error: "invalid_sequence" };
  }
  if (message.seq !== expectedSequence) return { error: "unexpected_sequence" };
  if (
    typeof message.envelope !== "string" ||
    message.envelope.length === 0 ||
    !ENVELOPE_PATTERN.test(message.envelope) ||
    message.envelope.length % 4 === 1
  ) {
    return { error: "invalid_envelope" };
  }
  const decodedLength = Buffer.from(message.envelope, "base64url").byteLength;
  if (decodedLength > maxEnvelopeBytes) return { error: "envelope_too_large" };
  return { value: message };
}
