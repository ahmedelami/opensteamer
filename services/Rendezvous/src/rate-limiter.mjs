export class FixedWindowLimiter {
  #entries = new Map();

  constructor({ limit, windowMs }) {
    this.limit = limit;
    this.windowMs = windowMs;
  }

  take(key, now = Date.now()) {
    let entry = this.#entries.get(key);
    if (!entry || now >= entry.resetAt) {
      entry = { count: 0, resetAt: now + this.windowMs };
      this.#entries.set(key, entry);
    }
    entry.count += 1;
    return Object.freeze({
      allowed: entry.count <= this.limit,
      remaining: Math.max(0, this.limit - entry.count),
      retryAfterMs: Math.max(0, entry.resetAt - now),
    });
  }

  prune(now = Date.now()) {
    for (const [key, entry] of this.#entries) {
      if (now >= entry.resetAt) this.#entries.delete(key);
    }
  }
}
