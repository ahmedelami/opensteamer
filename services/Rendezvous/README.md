# opensteamer rendezvous

This service connects one Mac host and one iPhone viewer long enough to negotiate a WebRTC session. It relays no media and receives no pairing secret. Both clients join `wss://…/v1/rendezvous` with the same unguessable channel ID and a `host` or `viewer` role, then exchange end-to-end-encrypted signaling envelopes that the service treats as opaque Base64URL strings. Session routing values are bounded WebSocket upgrade headers, not URL query parameters, so routine proxy access logs cannot retain them.

The channel ID must contain at least 128 bits of cryptographic randomness (22 Base64URL characters). It is a routing capability, not the user's pairing password. Do not substitute a six-digit code. The clients must derive encryption/authentication keys separately, authenticate the role and sequence inside each sealed envelope, and reject replayed or cross-channel messages.

## Run locally

Requires Node 20 or newer.

```sh
npm ci
STUN_URLS=stun:stun.example.com:3478 npm start
npm test
```

HTTP `GET /healthz` reports only aggregate pending/active counts. The WebSocket outer protocol is:

```text
GET /v1/rendezvous
X-AudioStreamer-Channel: <22-128 Base64URL chars>
X-AudioStreamer-Role: host|viewer
X-AudioStreamer-Admission: <43-char Base64URL proof>
client -> {"type":"signal","seq":0,"envelope":"<sealed Base64URL>"}
server -> {"type":"signal","from":"host","seq":0,"envelope":"<unchanged sealed Base64URL>"}
```

The `X-AudioStreamer-*` headers and `AudioStreamer.RemoteSession.HKDF-SHA256.v1\0`
domain below are deployed v1 compatibility ABI. Their former-brand spelling is intentional and
must remain stable so opensteamer clients interoperate with already deployed hosts and services.

The admission value is the unpadded Base64URL encoding of a separate 32-byte HKDF-SHA256 output derived from the invitation secret with salt `AudioStreamer.RemoteSession.HKDF-SHA256.v1\0` and info label `rendezvous-admission-proof`. The invitation secret itself is never transmitted. The service binds the host's proof to the invitation and uses a constant-time comparison before accepting a viewer, consuming the invitation, or issuing ICE credentials.

Sequences start at zero and increase by exactly one per sender. Envelopes, messages, connection attempts, and message rates are bounded. A host creates a short-lived invitation; the first correctly authenticated viewer consumes it permanently. The service allows at most one active host and viewer. It sends `waiting`, `ready`, `peer-left`, and `error` control messages. `ready` contains WebRTC ICE server configuration and, when TURN is enabled, a fresh expiring TURN credential.

## Production deployment

- Put the service behind a WebSocket-capable TLS reverse proxy. Never expose plaintext signaling on the public Internet.
- Reject query-based joins at every proxy layer; the public rendezvous URL is always exactly `/v1/rendezvous` and session values belong only in the three bounded upgrade headers.
- Keep the default loopback bind when the proxy runs on the same host. Restrict the container/network and expose only the proxy otherwise.
- Set `TRUST_PROXY_HOPS` only when every hop between the public listener and Node is trusted; this controls safe client-IP rate limiting.
- Supply TURN secrets through a secret manager. Logs intentionally contain no channel IDs, admission proofs, messages, URLs, provider key IDs, API tokens, or TURN credentials.
- Use a shared external rate limiter/session store before running multiple replicas. This in-process implementation is intentionally single-instance; naive load balancing would weaken consume-once and rate-limit guarantees.
- Terminate sessions client-side after WebRTC negotiation. The rendezvous is not a general data transport, and the envelope limit/message rates are deliberately unsuitable for media.

Direct ICE is preferred for latency. TURN is the required fallback for restrictive NAT, CGNAT, and firewalls. TURN relays DTLS-SRTP ciphertext, so it can observe network metadata and traffic volume but cannot decrypt WebRTC media.

## coturn REST credentials

Configure coturn and this service with the same high-entropy secret. A minimal coturn baseline is:

```ini
fingerprint
use-auth-secret
static-auth-secret=<injected by your secret manager>
realm=turn.example.com
no-loopback-peers
no-multicast-peers
min-port=49160
max-port=49200
```

Also configure the public/external IP, TLS certificate, listener addresses, firewall, and relay port range for the deployment. Prefer UDP TURN plus TLS/TCP fallback URLs. `TURN_URLS` without `TURN_SHARED_SECRET` is rejected at startup.

The `ready` message uses coturn's REST convention: `username = <expiry Unix seconds>:<random subject>` and `credential = Base64(HMAC-SHA1(shared secret, username))`. The shared secret itself is never sent. Keep credential TTL comfortably longer than ICE gathering but short enough to limit abuse; the default is ten minutes.

## Cloudflare Realtime TURN credentials

As an alternative to self-hosted coturn, configure both `CLOUDFLARE_TURN_KEY_ID` and
`CLOUDFLARE_TURN_API_TOKEN` through the server's secret manager. Do not configure
`TURN_URLS` or `TURN_SHARED_SECRET` at the same time. The API token stays server-side: the
rendezvous exchanges it only with Cloudflare's credential endpoint and sends clients only
the returned short-lived ICE username and password.

`TURN_CREDENTIAL_TTL_SECONDS` controls the requested credential lifetime (ten minutes by
default). `CLOUDFLARE_TURN_FETCH_TIMEOUT_MS` bounds the complete credential request to five
seconds by default. The response is size-bounded and strictly validated before use. The
service provisions a distinct credential for each peer and does not send `ready` to either
peer until both requests succeed. On any HTTP, timeout, parsing, or validation failure, both
peers receive the generic `ice_server_unavailable` error and are closed; provider response
bodies and errors are never logged.

See Cloudflare's [server-side credential generation documentation](https://developers.cloudflare.com/realtime/turn/generate-credentials/)
for creating and managing the TURN key. `STUN_URLS` remains optional; when set in managed
mode it is prepended to Cloudflare's returned ICE server list.

Copy `.env.example` for non-secret settings. It deliberately contains no secret value.
