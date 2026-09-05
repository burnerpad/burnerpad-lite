// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

// Privacy-safe end-to-end transaction for CI and the public scheduled canary. It reports only a fixed
// stage and validated release identity: never the temporary id, phrase, management token, ciphertext,
// plaintext, error detail, or full request path. Node >= 20 and the reviewed crypto library are required.
import { createRequire } from "node:module";
import crypto from "node:crypto";
import { createCanaryReporter } from "./canary-report.mjs";
import { parseCanaryOrigin } from "./origin.mjs";
import { waitUntilReady } from "./readiness.mjs";

const require = createRequire(import.meta.url);
const C = require("../../priv/static/vendor/crypto-js/burnerpad-crypto.js");
const configuredOrigin = process.env.BURNERPAD_BASE_URL || "";
const expectedRevision = process.env.BURNERPAD_EXPECTED_REVISION || "";
const requireExpectedRevision = process.env.BURNERPAD_REQUIRE_EXPECTED_REVISION === "true";
const requireHttpsOrigin = process.env.BURNERPAD_REQUIRE_HTTPS_ORIGIN === "true";
const timeoutMs = Number(process.env.BURNERPAD_CANARY_TIMEOUT_MS || 15_000);
const reporter = createCanaryReporter({ check: "end_to_end" });
const requireNoStore = (response) => {
  if (!/(?:^|,)\s*no-store\s*(?:,|$)/i.test(response.headers.get("cache-control") || "")) {
    throw new Error("missing no-store");
  }
  if ((response.headers.get("cf-cache-status") || "").toUpperCase() === "HIT") {
    throw new Error("edge cache hit on dynamic response");
  }
};

try {
  reporter.setStage("configuration");
  reporter.configureExpectedRevision(expectedRevision, { required: requireExpectedRevision });
  const origin = parseCanaryOrigin(configuredOrigin, { requireHttps: requireHttpsOrigin }).origin;
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error("canary timeout must be positive");

  const request = async (path, init = {}, requestTimeoutMs = timeoutMs) => {
    const signal = AbortSignal.timeout(Math.max(1, requestTimeoutMs));
    return fetch(origin + path, { redirect: "error", cache: "no-store", ...init, signal });
  };

  reporter.setStage("readiness");
  // A freshly started release may refuse connections for a few hundred milliseconds. Poll only the
  // readiness endpoint within the same bounded canary budget; transaction stages remain single-shot.
  if (!(await waitUntilReady({ request, timeoutMs }))) throw new Error("readiness rejected");

  // Capture the deployed identity before creating any capability material. A scheduled run also has an
  // independently maintained expected revision, which remains reportable if this public request fails.
  reporter.setStage("release_identity");
  const statsResponse = await request("/api/stats");
  if (!statsResponse.ok) throw new Error("stats rejected");
  requireNoStore(statsResponse);
  reporter.observeStats(await statsResponse.json());

  reporter.setStage("encrypt");
  const secret = "\uFEFFBurnerpad canary · 秘密 · 🧪 · e\u0301 · " + crypto.randomUUID();
  const phrase = crypto.randomBytes(32).toString("base64url");
  const plaintext = new TextEncoder().encode(secret);
  const encrypted = await C.encryptPsk(phrase, plaintext);
  plaintext.fill(0);

  reporter.setStage("create");
  const create = await request("/api/secrets", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({ blob: C.b64url(encrypted.blob), ttl: 60 }),
  });
  requireNoStore(create);
  encrypted.blob.fill(0);
  if (!create.ok) throw new Error("create rejected");
  const created = await create.json();
  if (created.ttl !== 60 || typeof created.id !== "string") throw new Error("invalid create response");

  reporter.setStage("reveal");
  const revealPath = "/api/secrets/" + encodeURIComponent(created.id) + "/reveal";
  const reveal = await request(revealPath, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: "{}",
  });
  requireNoStore(reveal);
  if (!reveal.ok) throw new Error("reveal rejected");
  const heldBlob = C.unb64url((await reveal.json()).blob);

  reporter.setStage("decrypt");
  const decrypted = await C.decryptPsk(heldBlob, phrase);
  heldBlob.fill(0);
  const recovered = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(decrypted);
  decrypted.fill(0);
  if (recovered !== secret) throw new Error("plaintext mismatch");

  reporter.setStage("at_most_once");
  const second = await request(revealPath, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: "{}",
  });
  requireNoStore(second);
  if (second.status !== 404) throw new Error("second reveal was not gone");

  reporter.succeeded();
} catch (_error) {
  reporter.failed();
  process.exitCode = 1;
}
