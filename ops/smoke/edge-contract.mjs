// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

// Public Cloudflare delivery contract. Checks only public, non-capability paths and never emits full URLs.
import crypto from "node:crypto";
import https from "node:https";
import { createCanaryReporter } from "./canary-report.mjs";
import { requireDynamicNoStore, requireStaticRevalidation } from "./edge-cache-contract.mjs";
import { verifySourceIdentity } from "./edge-source-contract.mjs";

const origin = (process.env.BURNERPAD_BASE_URL || "").replace(/\/$/, "");
const expectedRevision = process.env.BURNERPAD_EXPECTED_REVISION || "";
const requireExpectedRevision = process.env.BURNERPAD_REQUIRE_EXPECTED_REVISION === "true";
const timeout = Number(process.env.BURNERPAD_CANARY_TIMEOUT_MS || 15_000);
const reporter = createCanaryReporter({ check: "edge_contract" });
const get = (url, init = {}) => fetch(url, {
  redirect: "manual",
  cache: "no-store",
  signal: AbortSignal.timeout(timeout),
  ...init,
});
const sri = (bytes) => "sha384-" + crypto.createHash("sha384").update(bytes).digest("base64");

try {
  reporter.setStage("configuration");
  reporter.configureExpectedRevision(expectedRevision, { required: requireExpectedRevision });
  if (!Number.isFinite(timeout) || timeout <= 0) throw new Error("canary timeout must be positive");
  const parsed = new URL(origin);
  if (parsed.protocol !== "https:" || parsed.pathname !== "/") {
    throw new Error("BURNERPAD_BASE_URL must be an HTTPS origin without a path");
  }

  const legacyTlsRejected = () => new Promise((resolve, reject) => {
    const req = https.request({
      hostname: parsed.hostname,
      port: parsed.port || 443,
      path: "/healthz",
      method: "GET",
      servername: parsed.hostname,
      minVersion: "TLSv1",
      maxVersion: "TLSv1.1",
      timeout,
    });
    req.on("response", (response) => {
      response.resume();
      reject(new Error("TLS 1.1 was accepted"));
    });
    req.on("error", () => resolve());
    req.on("timeout", () => req.destroy(new Error("TLS timeout")));
    req.end();
  });

  // Resolve the deployed release before the other public checks so every later failure is attributable.
  reporter.setStage("api_cache");
  const api = await get(origin + "/api/stats");
  if (!api.ok || !/no-store/i.test(api.headers.get("cache-control") || "")) {
    throw new Error("API cache contract missing");
  }
  if ((api.headers.get("cf-cache-status") || "").toUpperCase() === "HIT") {
    throw new Error("API edge-cache hit");
  }
  reporter.setStage("release_identity");
  reporter.observeStats(await api.json());

  for (const { path, body, stage } of [
    { path: "/healthz", body: "ok", stage: "health_cache" },
    { path: "/readyz", body: "ready", stage: "readiness_cache" },
  ]) {
    reporter.setStage(stage);
    for (const method of ["GET", "HEAD"]) {
      const response = await get(origin + path, { method });
      requireDynamicNoStore(response);
      if (method === "GET" && (await response.text()) !== body) {
        throw new Error("health response body changed");
      }
    }
  }

  reporter.setStage("https_redirect");
  const insecure = await get("http://" + parsed.host + "/healthz");
  const location = insecure.headers.get("location") || "";
  if (![301, 302, 307, 308].includes(insecure.status) || !location.startsWith(origin + "/")) {
    throw new Error("HTTP did not redirect to the canonical HTTPS origin");
  }

  reporter.setStage("minimum_tls");
  await legacyTlsRejected();

  reporter.setStage("html_headers");
  const page = await get(origin + "/");
  if (!page.ok) throw new Error("homepage rejected");
  const hsts = page.headers.get("strict-transport-security") || "";
  const csp = page.headers.get("content-security-policy") || "";
  if (!/includesubdomains/i.test(hsts) || !/preload/i.test(hsts)) throw new Error("HSTS contract missing");
  if (!/default-src 'none'/.test(csp) || !/script-src 'self'/.test(csp)) throw new Error("CSP contract missing");
  if (!/no-store/i.test(page.headers.get("cache-control") || "")) throw new Error("HTML is cacheable");
  if ((page.headers.get("cf-cache-status") || "").toUpperCase() === "HIT") throw new Error("HTML edge-cache hit");
  const html = await page.text();
  if (/rocket-loader|cdn-cgi\/scripts|data-cfasync|<script[^>]*>\s*\S/i.test(html)) {
    throw new Error("HTML/script transformation detected");
  }

  reporter.setStage("sri_assets");
  const pins = new Map();
  for (const match of html.matchAll(/<(?:script|link)\b[^>]*(?:src|href)="(\/crypto\/[^"]+)"[^>]*integrity="(sha384-[^"]+)"/g)) {
    pins.set(match[1], match[2]);
  }
  if (pins.size !== 4) throw new Error("unexpected SRI asset set");
  for (const [path, expected] of pins) {
    const asset = await get(origin + path);
    if (!asset.ok) throw new Error("asset rejected");
    const cache = asset.headers.get("cache-control") || "";
    if (!/no-cache/i.test(cache) || /immutable/i.test(cache)) throw new Error("unsafe stable-path cache policy");
    const actual = sri(Buffer.from(await asset.arrayBuffer()));
    if (actual !== expected) throw new Error("public asset differs from its SRI pin");

    reporter.setStage("sri_revalidation");
    const etag = asset.headers.get("etag") || "";
    const conditional = await get(origin + path, { headers: { "if-none-match": etag } });
    requireStaticRevalidation(asset, conditional);
    reporter.setStage("sri_assets");
  }

  reporter.setStage("client_ip");
  try {
    await verifySourceIdentity(get, origin);
  } catch (error) {
    if (typeof error?.stage === "string") reporter.setStage(error.stage);
    throw error;
  }

  reporter.succeeded();
} catch (_error) {
  reporter.failed();
  process.exitCode = 1;
}
