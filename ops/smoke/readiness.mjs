// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

const defaultSleep = (delayMs) => new Promise((resolve) => setTimeout(resolve, delayMs));

const requireNoStore = (response) => {
  if (!/(?:^|,)\s*no-store\s*(?:,|$)/i.test(response.headers.get("cache-control") || "")) {
    throw new Error("missing no-store");
  }
  if ((response.headers.get("cf-cache-status") || "").toUpperCase() === "HIT") {
    throw new Error("edge cache hit on dynamic response");
  }
};

export const waitUntilReady = async ({
  request,
  timeoutMs,
  now = Date.now,
  sleep = defaultSleep,
  pollMs = 200,
}) => {
  const deadline = now() + timeoutMs;

  while (now() < deadline) {
    try {
      const health = await request("/readyz", {}, deadline - now());
      requireNoStore(health);
      if (health.ok && (await health.text()) === "ready") return true;
    } catch (_error) {
      // Connection refusal during the bounded startup window is expected.
    }

    const remainingMs = Math.max(0, deadline - now());
    if (remainingMs > 0) await sleep(Math.min(pollMs, remainingMs));
  }

  return false;
};
