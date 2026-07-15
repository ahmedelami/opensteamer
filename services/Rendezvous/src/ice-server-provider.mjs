import { createCloudflareTurnProvider } from "./cloudflare-turn-provider.mjs";
import { buildIceServers } from "./turn-credentials.mjs";

export function createIceServerProvider(config, options = {}) {
  if (config.cloudflareTurnKeyId) {
    const managedProvider = createCloudflareTurnProvider({
      keyId: config.cloudflareTurnKeyId,
      apiToken: config.cloudflareTurnApiToken,
      ttlSeconds: config.turnCredentialTtlSeconds,
      timeoutMs: config.cloudflareTurnFetchTimeoutMs,
      fetchImpl: options.fetchImpl,
    });
    return async () => {
      const managedIceServers = await managedProvider();
      if (config.stunUrls.length === 0) return managedIceServers;
      return Object.freeze([
        Object.freeze({ urls: Object.freeze([...config.stunUrls]) }),
        ...managedIceServers,
      ]);
    };
  }

  return async () =>
    buildIceServers(config, {
      now: options.now?.(),
      randomBytes: options.randomBytes,
    });
}
