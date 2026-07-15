import { describe, expect, it, vi } from "vitest";
import {
  TurnProvisioningError,
  iceServersForJoin,
  normalizeCloudflareIceServers,
} from "../src/ice.js";

const cloudflarePayload = {
  iceServers: [
    { urls: ["stun:stun.cloudflare.com:3478"] },
    {
      urls: [
        "turn:turn.cloudflare.com:3478?transport=udp",
        "turns:turn.cloudflare.com:443?transport=tcp",
      ],
      username: "ephemeral-user",
      credential: "ephemeral-password",
    },
  ],
};

describe("ICE provisioning", () => {
  it("uses direct-STUN-only configuration when both TURN secrets are absent", async () => {
    await expect(iceServersForJoin({ STUN_URLS: "stun:one.example:3478" })).resolves.toEqual([
      { urls: ["stun:one.example:3478"] },
    ]);
  });

  it("fetches short-lived credentials server-side and normalizes the strict response", async () => {
    const fetchImpl = vi.fn(async () =>
      new Response(JSON.stringify(cloudflarePayload), {
        status: 201,
        headers: { "Content-Type": "application/json" },
      }),
    );
    const env = {
      CLOUDFLARE_TURN_KEY_ID: "key_123",
      CLOUDFLARE_TURN_API_TOKEN: "server-secret-token",
      TURN_CREDENTIAL_TTL_SECONDS: "600",
      TURN_FETCH_TIMEOUT_MS: "1000",
    };

    const result = await iceServersForJoin(env, fetchImpl);
    expect(result[1]).toEqual({
      ...cloudflarePayload.iceServers[1],
      credentialType: "password",
    });
    const [url, request] = fetchImpl.mock.calls[0];
    expect(url).toContain("/keys/key_123/credentials/generate-ice-servers");
    expect(request.headers.Authorization).toBe("Bearer server-secret-token");
    expect(JSON.parse(request.body)).toEqual({ ttl: 600 });
  });

  it("rejects partial configuration and response schema additions", async () => {
    await expect(
      iceServersForJoin({ CLOUDFLARE_TURN_KEY_ID: "key-without-token" }),
    ).rejects.toBeInstanceOf(TurnProvisioningError);
    expect(() =>
      normalizeCloudflareIceServers({ ...cloudflarePayload, unexpected: true }),
    ).toThrow(TurnProvisioningError);
    expect(() =>
      normalizeCloudflareIceServers({
        iceServers: [
          {
            urls: "turn:attacker.example:3478?transport=udp",
            username: "u",
            credential: "p",
          },
        ],
      }),
    ).toThrow(TurnProvisioningError);
  });
});
