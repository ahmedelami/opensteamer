export const HEADER = Object.freeze({
  channel: "X-AudioStreamer-Channel",
  role: "X-AudioStreamer-Role",
  admission: "X-AudioStreamer-Admission",
});

export const LIMITS = Object.freeze({
  maximumChannelBytes: 128,
  maximumWireMessageBytes: 90_000,
  maximumEnvelopeBytes: 65_536,
  maximumSequence: 2_147_483_647,
  messageRateWindowMs: 60_000,
  messageRateLimit: 300,
});

const CHANNEL_PATTERN = /^[A-Za-z0-9_-]{22,128}$/;
const ADMISSION_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;
const BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });

export const utf8Length = (value) => textEncoder.encode(value).byteLength;

const exactKeys = (value, expected) => {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const keys = Object.keys(value).sort();
  return keys.length === expected.length && keys.every((key, index) => key === expected[index]);
};

const bytesToBinary = (bytes) => {
  let result = "";
  for (let index = 0; index < bytes.byteLength; index += 0x8000) {
    result += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return result;
};

const decodeCanonicalBase64URL = (value) => {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length % 4 === 1 ||
    !BASE64URL_PATTERN.test(value)
  ) {
    return undefined;
  }
  try {
    const standard = value.replaceAll("-", "+").replaceAll("_", "/");
    const binary = atob(standard + "=".repeat((4 - (standard.length % 4)) % 4));
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    const canonical = btoa(bytesToBinary(bytes))
      .replaceAll("+", "-")
      .replaceAll("/", "_")
      .replace(/=+$/, "");
    return canonical === value ? bytes : undefined;
  } catch {
    return undefined;
  }
};

const validCanonicalCiphertext = (value) => {
  if (typeof value !== "string" || value.length === 0 || !BASE64_PATTERN.test(value)) {
    return false;
  }
  try {
    const binary = atob(value);
    return btoa(binary) === value && binary.length <= LIMITS.maximumEnvelopeBytes;
  } catch {
    return false;
  }
};

export function validateJoinHeaders(headers) {
  const channel = headers.get(HEADER.channel);
  const role = headers.get(HEADER.role);
  const admission = headers.get(HEADER.admission);
  if (
    typeof channel !== "string" ||
    utf8Length(channel) > LIMITS.maximumChannelBytes ||
    !CHANNEL_PATTERN.test(channel)
  ) {
    return { error: "invalid_channel" };
  }
  if (role !== "host" && role !== "viewer") return { error: "invalid_role" };
  const proofBytes = decodeCanonicalBase64URL(admission);
  if (!ADMISSION_PATTERN.test(admission ?? "") || proofBytes?.byteLength !== 32) {
    return { error: "invalid_admission" };
  }
  return { value: { channel, role, admission, proofBytes } };
}

export function admissionProofsMatch(expectedValue, receivedBytes) {
  const expectedBytes = decodeCanonicalBase64URL(expectedValue);
  if (expectedBytes?.byteLength !== 32 || receivedBytes?.byteLength !== 32) return false;
  let difference = 0;
  for (let index = 0; index < 32; index += 1) {
    difference |= expectedBytes[index] ^ receivedBytes[index];
  }
  return difference === 0;
}

function validateSealedEnvelope(bytes, { channel, role, sequence }) {
  let envelope;
  try {
    envelope = JSON.parse(textDecoder.decode(bytes));
  } catch {
    return false;
  }
  if (
    !exactKeys(envelope, ["channelID", "ciphertext", "direction", "sequence", "version"])
  ) {
    return false;
  }
  const expectedDirection = role === "host" ? "hostToViewer" : "viewerToHost";
  return (
    envelope.version === 1 &&
    envelope.channelID === channel &&
    envelope.direction === expectedDirection &&
    Number.isSafeInteger(envelope.sequence) &&
    envelope.sequence === sequence &&
    validCanonicalCiphertext(envelope.ciphertext)
  );
}

export function validateSignal(raw, { channel, role, expectedSequence }) {
  if (typeof raw !== "string" || utf8Length(raw) > LIMITS.maximumWireMessageBytes) {
    return { error: "invalid_message" };
  }

  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    return { error: "invalid_json" };
  }
  if (!exactKeys(message, ["envelope", "seq", "type"]) || message.type !== "signal") {
    return { error: "invalid_message" };
  }
  if (
    !Number.isSafeInteger(message.seq) ||
    message.seq < 0 ||
    message.seq > LIMITS.maximumSequence
  ) {
    return { error: "invalid_sequence" };
  }
  if (message.seq !== expectedSequence) return { error: "unexpected_sequence" };

  const envelopeBytes = decodeCanonicalBase64URL(message.envelope);
  if (!envelopeBytes) return { error: "invalid_envelope" };
  if (envelopeBytes.byteLength > LIMITS.maximumEnvelopeBytes) {
    return { error: "envelope_too_large" };
  }
  if (!validateSealedEnvelope(envelopeBytes, { channel, role, sequence: message.seq })) {
    return { error: "invalid_envelope" };
  }
  return { value: message };
}
