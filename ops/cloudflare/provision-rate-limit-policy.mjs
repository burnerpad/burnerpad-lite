// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import { pathToFileURL } from "node:url";
import { expectedRules, policy, validateRuleset } from "./audit-rate-limit-policy.mjs";

const apiRequest = async (url, options, fetchImpl) => {
  try {
    return await fetchImpl(url, {
      ...options,
      headers: {
        authorization: options.headers.authorization,
        accept: "application/json",
        ...(options.body ? { "content-type": "application/json" } : {}),
      },
      redirect: "error",
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new Error("Cloudflare Rulesets API was unavailable");
  }
};

const successfulPayload = async (response, action) => {
  if (!response.ok) throw new Error(`Cloudflare rejected the ${action}`);
  try {
    const payload = await response.json();
    if (payload?.success !== true) throw new Error("failed result");
    return payload;
  } catch {
    throw new Error(`Cloudflare returned an invalid result for the ${action}`);
  }
};

export const provisionRateLimitPolicy = async ({ env = process.env, fetchImpl = fetch } = {}) => {
  const zoneId = env.CLOUDFLARE_ZONE_ID || "";
  const writeToken = env.CLOUDFLARE_RULESETS_WRITE_TOKEN || "";

  if (!/^[0-9a-f]{32}$/.test(zoneId)) throw new Error("invalid Cloudflare zone id");
  if (writeToken.length < 20) throw new Error("missing temporary Cloudflare Zone WAF write token");

  const baseUrl = `https://api.cloudflare.com/client/v4/zones/${zoneId}/rulesets`;
  const authorization = `Bearer ${writeToken}`;
  const current = await apiRequest(
    `${baseUrl}/phases/${policy.phase}/entrypoint`,
    { headers: { authorization } },
    fetchImpl,
  );

  if (current.ok) {
    const payload = await successfulPayload(current, "rate-limit read");
    try {
      validateRuleset(payload.result);
    } catch {
      throw new Error(
        "an http_ratelimit ruleset already exists but differs; refusing to overwrite it",
      );
    }
    return "already-configured";
  }
  if (current.status !== 404) throw new Error("Cloudflare rejected the rate-limit read");

  const create = await apiRequest(
    baseUrl,
    {
      method: "POST",
      headers: { authorization },
      body: JSON.stringify({
        name: policy.ruleset_name,
        description: policy.ruleset_description,
        kind: "zone",
        phase: policy.phase,
        rules: expectedRules(),
      }),
    },
    fetchImpl,
  );
  const payload = await successfulPayload(create, "rate-limit creation");
  try {
    validateRuleset(payload.result);
  } catch {
    throw new Error(
      "Cloudflare created a ruleset that does not match the required Free-plan policy",
    );
  }
  return "created";
};

const main = async () => {
  if (!process.argv.includes("--apply")) {
    throw new Error("refusing to change Cloudflare without the explicit --apply option");
  }
  const result = await provisionRateLimitPolicy();
  console.log(`Cloudflare Free-plan rate-limit policy ${result}`);
};

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await main();
  } catch (error) {
    console.error(`Cloudflare rate-limit provisioning failed: ${error.message}`);
    process.exitCode = 1;
  }
}
