export const HEADER = Object.freeze({
  channel: "X-AudioStreamer-Channel",
  role: "X-AudioStreamer-Role",
  admission: "X-AudioStreamer-Admission",
  viewerAdmission: "X-AudioStreamer-Viewer-Admission",
  mode: "X-AudioStreamer-Mode",
  webSocketProtocol: "Sec-WebSocket-Protocol",
});

export const AVAILABILITY_WEBSOCKET_PROTOCOL = "audiostreamer.availability.v1";
export const PAIRING_WEBSOCKET_PROTOCOL = "audiostreamer.pairing.v1";

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
const EXCHANGE_ID_PATTERN = /^[A-Za-z0-9_-]{22}$/;
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

export function validateJoinHeaders(headers, expectedMode = "invitation") {
  const channel = headers.get(HEADER.channel);
  const role = headers.get(HEADER.role);
  const admission = headers.get(HEADER.admission);
  const viewerAdmission = headers.get(HEADER.viewerAdmission);
  const modeHeader = headers.get(HEADER.mode);
  const webSocketProtocol = headers.get(HEADER.webSocketProtocol);
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

  if (expectedMode !== "invitation" && expectedMode !== "availability") {
    return { error: "invalid_mode" };
  }
  let selectedMode = expectedMode;
  if (expectedMode === "invitation") {
    if (modeHeader !== null) return { error: "invalid_mode" };
    if (viewerAdmission !== null) return { error: "invalid_viewer_admission" };
    if (webSocketProtocol === PAIRING_WEBSOCKET_PROTOCOL) {
      selectedMode = "pairing";
    } else if (webSocketProtocol !== null) {
      return { error: "invalid_websocket_protocol" };
    }
  } else if (modeHeader !== "availability") {
    return { error: "invalid_mode" };
  } else if (webSocketProtocol !== AVAILABILITY_WEBSOCKET_PROTOCOL) {
    return { error: "invalid_websocket_protocol" };
  }

  let viewerProofBytes;
  if (expectedMode === "availability" && role === "host") {
    viewerProofBytes = decodeCanonicalBase64URL(viewerAdmission);
    if (
      !ADMISSION_PATTERN.test(viewerAdmission ?? "") ||
      viewerProofBytes?.byteLength !== 32
    ) {
      return { error: "invalid_viewer_admission" };
    }
  } else if (viewerAdmission !== null) {
    return { error: "invalid_viewer_admission" };
  }

  return {
    value: {
      channel,
      role,
      admission,
      proofBytes,
      viewerAdmission,
      viewerProofBytes,
      mode: selectedMode,
    },
  };
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

const validCanonical128BitBase64URL = (value) => {
  if (typeof value !== "string" || !EXCHANGE_ID_PATTERN.test(value)) return false;
  return decodeCanonicalBase64URL(value)?.byteLength === 16;
};

const validExchangeID = validCanonical128BitBase64URL;

// Probe inspection is deliberately non-consuming for all other availability messages, which
// continue through the encrypted-signal validator. Once the exact probe type is present, however,
// its schema and 128-bit nonce must be canonical or the caller fails closed as invalid_message.
export function inspectAvailabilityProbe(raw) {
  if (typeof raw !== "string" || utf8Length(raw) > LIMITS.maximumWireMessageBytes) {
    return { matched: false };
  }

  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    return { matched: false };
  }
  if (
    message === null ||
    typeof message !== "object" ||
    Array.isArray(message) ||
    message.type !== "availability-probe"
  ) {
    return { matched: false };
  }
  if (
    !exactKeys(message, ["nonce", "type"]) ||
    !validCanonical128BitBase64URL(message.nonce)
  ) {
    return { matched: true, error: "invalid_message" };
  }
  return { matched: true, value: message };
}

function validateAvailabilityEnvelope(bytes, { channel, role, exchangeID, sequence }) {
  let envelope;
  try {
    envelope = JSON.parse(textDecoder.decode(bytes));
  } catch {
    return false;
  }
  if (
    !exactKeys(envelope, [
      "channelID",
      "ciphertext",
      "direction",
      "exchangeID",
      "sequence",
      "version",
    ])
  ) {
    return false;
  }
  const expectedDirection = role === "host" ? "hostToViewer" : "viewerToHost";
  return (
    envelope.version === 1 &&
    envelope.channelID === channel &&
    envelope.exchangeID === exchangeID &&
    envelope.direction === expectedDirection &&
    Number.isSafeInteger(envelope.sequence) &&
    envelope.sequence === sequence &&
    validCanonicalCiphertext(envelope.ciphertext)
  );
}

export function validateAvailabilitySignal(
  raw,
  { channel, role, exchangeID, expectedSequence },
) {
  if (typeof raw !== "string" || utf8Length(raw) > LIMITS.maximumWireMessageBytes) {
    return { error: "invalid_message" };
  }

  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    return { error: "invalid_json" };
  }
  if (
    !exactKeys(message, ["envelope", "exchangeID", "seq", "type"]) ||
    message.type !== "availability-signal"
  ) {
    return { error: "invalid_message" };
  }
  if (!validExchangeID(message.exchangeID) || message.exchangeID !== exchangeID) {
    return { error: "invalid_exchange" };
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
  if (
    !validateAvailabilityEnvelope(envelopeBytes, {
      channel,
      role,
      exchangeID,
      sequence: message.seq,
    })
  ) {
    return { error: "invalid_envelope" };
  }
  return { value: message };
}
