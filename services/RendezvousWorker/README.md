# AudioStreamer Cloudflare rendezvous

This Worker is the public signaling control plane for AudioStreamer's direct WebRTC path. It deploys to a stable `workers.dev` hostname and routes each unguessable channel to one SQLite-backed Durable Object. The Worker and Durable Object never relay media or decrypt signaling envelopes.

The public surface is deliberately small:

- `GET /healthz` returns `{"ok":true}` and no session data.
- `WSS /v1/rendezvous` is the only upgrade route.
- Channel, role, and admission proof are accepted only in the bounded `X-AudioStreamer-Channel`, `X-AudioStreamer-Role`, and `X-AudioStreamer-Admission` upgrade headers. Query-based and alternate-path joins are rejected.

The Durable Object stores the first host's admission proof, expiration, consumed bit, and a bounded tombstone. It compares the viewer's separate 32-byte proof before checking viewer occupancy, consuming the invitation, or provisioning TURN. Hibernating WebSocket attachments retain role, generation, next sequence, last activity, and rate-window state. No source path logs channels, proofs, payloads, TURN identifiers, tokens, or credentials.

## Local verification

Requires Node.js 20 or newer.

```sh
npm ci
npm test
npm run check
npm run dev
```

The pinned Vitest/Workers pool runs the tests in the Workers runtime with a real local Durable Object. Tests cover strict headers and envelopes, host-first admission, proof mismatch, direct-STUN readiness, unchanged forwarding, hibernation recovery, peer departure, consume-once rejection, and non-disclosure through application logs. `npm run check` performs a local Wrangler production bundle dry run and does not deploy.

## TURN modes

With neither TURN secret configured, `ready` contains only the `STUN_URLS` configured in `wrangler.toml`. This is useful for direct ICE and development, but it does **not** provide worldwide reliability: restrictive NAT, CGNAT, and firewalls still require TURN.

For production, create a Cloudflare Realtime TURN key and set both server-side secrets:

```sh
npx wrangler secret put CLOUDFLARE_TURN_KEY_ID
npx wrangler secret put CLOUDFLARE_TURN_API_TOKEN
```

If exactly one secret is present, or credential provisioning times out or returns an invalid response, the viewer is rejected with `turn_unavailable`; the invitation is not consumed. The Worker accepts only a bounded `201 application/json` response, restricts provisioned ICE URLs to Cloudflare's expected `stun.cloudflare.com` and `turn.cloudflare.com` hosts and STUN/TURN transports, normalizes strict password-credential schemas, and never persists generated credentials. `.dev.vars.example` documents local secret names; `.dev.vars` is ignored.

## Deployment

Review the account and TURN billing configuration first, then deploy explicitly:

```sh
npm ci
npm test
npm run check
npm run deploy
```

Wrangler creates the `RendezvousSession` class with the `new_sqlite_classes` migration, which is compatible with Workers Free Durable Objects. With the default name, the stable endpoint is:

```text
wss://audiostreamer-rendezvous.<workers-subdomain>.workers.dev
```

Configure the Mac and iOS clients with that origin only; their shared Swift client appends `/v1/rendezvous`. Do not put a channel, role, proof, or pairing code in the URL. The deployed path prefers direct WebRTC ICE and uses TURN only when direct connectivity fails.

The included `JOIN_RATE_LIMITER` binding limits syntactically valid upgrades per edge-observed actor and per channel before a Durable Object is invoked. Its numeric namespace must remain unique within the Cloudflare account; change `namespace_id` before deployment if `1001001` is already used. Cloudflare's binding is intentionally local and eventually consistent, so account-level WAF/bot rules remain useful defense in depth. Per-connection message limits are enforced inside each Durable Object, while the one-object-per-channel design serializes role occupancy and consume-once state.

## Wire behavior

The control messages match the Node rendezvous implementation:

```text
server -> {"type":"waiting","invitationExpiresAt":"..."}
server -> {"type":"ready","role":"host|viewer","invitationExpiresAt":"...","iceServers":[...]}
client -> {"type":"signal","seq":0,"envelope":"<canonical Base64URL>"}
server -> {"type":"signal","from":"host|viewer","seq":0,"envelope":"<unchanged Base64URL>"}
server -> {"type":"peer-left","role":"host|viewer"}
server -> {"type":"error","error":"<bounded_code>"}
```

Signals must start at sequence zero and increase by exactly one for each sender. The outer message, decoded sealed-envelope schema, channel, direction, inner sequence, ciphertext encoding, total wire size, and message rate are all bounded before forwarding.
