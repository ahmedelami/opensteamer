/**
 * Local WebSocket-to-TCP adapter for the legacy opensteamer relay diagnostic path.
 *
 * Run `npm install` once, then provide `RELAY_TOKEN` (or `MCAP_TOKEN`) and use `npm start`.
 * The HTTP/WebSocket listener is bound to 127.0.0.1 and is intentionally limited to trusted-local
 * diagnostics. `/health` reports process readiness, while `/stream` requires a JSON text frame of
 * `{ "type": "auth", "token": "..." }` within five seconds before any capture connection opens.
 *
 * Environment variables:
 * - RELAY_BRIDGE_PORT: local HTTP/WebSocket port (default 8787).
 * - CAPTURE_HOST / CAPTURE_PORT: CaptureServer TCP destination (defaults 127.0.0.1:9000).
 * - RELAY_TOKEN: WebSocket client credential; falls back to MCAP_TOKEN.
 * - MCAP_TOKEN: credential forwarded in CaptureServer's binary authentication header.
 * - WS_HIGH_WATER_BYTES / WS_LOW_WATER_BYTES / WS_CRITICAL_BYTES: backpressure thresholds.
 *
 * The process accepts network connections and opens one outbound TCP socket per authenticated
 * viewer. It creates no files and never logs credentials. Startup without a relay token exits 1;
 * runtime socket failures close the affected WebSocket with an error code while the server stays up.
 */
import http from "node:http";
import net from "node:net";
import { timingSafeEqual } from "node:crypto";
import { WebSocketServer, WebSocket } from "ws";

const listenPort = Number.parseInt(process.env.RELAY_BRIDGE_PORT ?? "8787", 10);
const captureHost = process.env.CAPTURE_HOST ?? "127.0.0.1";
const capturePort = Number.parseInt(process.env.CAPTURE_PORT ?? "9000", 10);
const relayToken = process.env.RELAY_TOKEN ?? process.env.MCAP_TOKEN ?? "";
const captureToken = process.env.MCAP_TOKEN ?? relayToken;
const wsHighWaterBytes = Number.parseInt(process.env.WS_HIGH_WATER_BYTES ?? String(2 * 1024 * 1024), 10);
const wsLowWaterBytes = Number.parseInt(process.env.WS_LOW_WATER_BYTES ?? String(512 * 1024), 10);
const wsCriticalBytes = Number.parseInt(process.env.WS_CRITICAL_BYTES ?? String(8 * 1024 * 1024), 10);

if (!relayToken) {
  console.error("RELAY_TOKEN or MCAP_TOKEN is required");
  process.exit(1);
}

// The health response proves only that this bridge is listening; CaptureServer connectivity is
// established lazily after viewer authentication and is represented by the stream itself.
const server = http.createServer((request, response) => {
  if (request.url === "/" || request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      ok: true,
      service: "opensteamer-relay-bridge",
      stream: "/stream"
    }));
    return;
  }

  response.writeHead(404, { "content-type": "text/plain" });
  response.end("not found\n");
});

const wss = new WebSocketServer({
  server,
  path: "/stream",
  maxPayload: 2048
});

wss.on("connection", (ws, request) => {
  const remote = request.headers["cf-connecting-ip"] ?? request.socket.remoteAddress ?? "unknown";
  let authed = false;
  let captureSocket;

  // Unauthenticated sockets receive no capture data and occupy the bridge for at most five seconds.
  const authTimer = setTimeout(() => {
    if (!authed) {
      ws.close(1008, "auth timeout");
    }
  }, 5000);

  ws.on("message", (message, isBinary) => {
    if (authed) {
      return;
    }

    if (isBinary) {
      ws.close(1008, "auth required");
      return;
    }

    let payload;
    try {
      payload = JSON.parse(message.toString("utf8"));
    } catch {
      ws.close(1008, "invalid auth");
      return;
    }

    if (payload?.type !== "auth" || typeof payload.token !== "string") {
      ws.close(1008, "invalid auth");
      return;
    }

    if (!constantTimeEquals(payload.token, relayToken)) {
      ws.close(1008, "auth failed");
      return;
    }

    authed = true;
    clearTimeout(authTimer);
    console.log(`client authenticated from ${remote}`);
    captureSocket = connectCapture(ws);
  });

  ws.on("close", () => {
    clearTimeout(authTimer);
    captureSocket?.destroy();
  });

  ws.on("error", () => {
    clearTimeout(authTimer);
    captureSocket?.destroy();
  });
});

server.listen(listenPort, "127.0.0.1", () => {
  console.log(`relay bridge listening at http://127.0.0.1:${listenPort}/stream`);
  console.log(`forwarding to CaptureServer at ${captureHost}:${capturePort}`);
});

function connectCapture(ws) {
  // CaptureServer authentication is the first TCP payload; the WebSocket credential is never
  // forwarded as JSON or exposed to the binary stream.
  const socket = net.createConnection({ host: captureHost, port: capturePort }, () => {
    socket.write(makeCaptureAuthRequest(captureToken));
  });
  let resumeTimer;

  // Pause the TCP producer when WebSocket buffering grows, then poll until the lower threshold is
  // reached. The separate critical threshold bounds memory when a viewer falls irrecoverably behind.
  const scheduleResume = () => {
    if (resumeTimer || socket.destroyed) {
      return;
    }

    resumeTimer = setInterval(() => {
      if (socket.destroyed || ws.readyState !== WebSocket.OPEN) {
        clearInterval(resumeTimer);
        resumeTimer = undefined;
        return;
      }

      if (ws.bufferedAmount <= wsLowWaterBytes) {
        clearInterval(resumeTimer);
        resumeTimer = undefined;
        socket.resume();
      }
    }, 25);
  };

  socket.on("data", (chunk) => {
    if (ws.readyState !== WebSocket.OPEN) {
      return;
    }

    if (ws.bufferedAmount > wsCriticalBytes) {
      ws.close(1011, "client is too far behind");
      socket.destroy();
      return;
    }

    ws.send(chunk, { binary: true }, (error) => {
      if (error && ws.readyState === WebSocket.OPEN) {
        ws.close(1011, "websocket send failed");
      }
    });

    if (ws.bufferedAmount > wsHighWaterBytes) {
      socket.pause();
      scheduleResume();
    }
  });

  socket.on("close", () => {
    if (resumeTimer) {
      clearInterval(resumeTimer);
      resumeTimer = undefined;
    }
    if (ws.readyState === WebSocket.OPEN) {
      ws.close(1011, "capture closed");
    }
  });

  socket.on("error", (error) => {
    if (resumeTimer) {
      clearInterval(resumeTimer);
      resumeTimer = undefined;
    }
    if (ws.readyState === WebSocket.OPEN) {
      ws.close(1011, `capture error: ${error.code ?? "unknown"}`);
    }
  });

  return socket;
}

function makeCaptureAuthRequest(token) {
  const tokenBytes = Buffer.from(token, "utf8");
  if (tokenBytes.length === 0 || tokenBytes.length > 512) {
    throw new Error("capture token must be 1...512 bytes");
  }

  // Wire format: ASCII magic, little-endian protocol version, little-endian UTF-8 byte count,
  // followed by the token bytes. The 512-byte cap matches CaptureServer's framing contract.
  const header = Buffer.alloc(8 + tokenBytes.length);
  header.write("MCAT", 0, "ascii");
  header.writeUInt16LE(1, 4);
  header.writeUInt16LE(tokenBytes.length, 6);
  tokenBytes.copy(header, 8);
  return header;
}

function constantTimeEquals(lhs, rhs) {
  const left = Buffer.from(lhs, "utf8");
  const right = Buffer.from(rhs, "utf8");
  if (left.length !== right.length) {
    // `timingSafeEqual` requires equal lengths; token contents are compared only through it.
    return false;
  }
  return timingSafeEqual(left, right);
}
