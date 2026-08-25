// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import { readFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";
import { pathToFileURL } from "node:url";

export const policy = JSON.parse(
  readFileSync(new URL("./rate-limit-policy.json", import.meta.url), "utf8"),
);

export const AUDIT_EXIT = Object.freeze({
  invalidConfiguration: 2,
  missingRuleset: 10,
  accessDenied: 11,
  apiUnavailable: 12,
  policyDrift: 20,
});

export class RateLimitAuditError extends Error {
  constructor(message, exitCode) {
    super(message);
    this.name = "RateLimitAuditError";
    this.exitCode = exitCode;
  }
}

const projectExpectedFields = (actual, expected) => {
  if (Array.isArray(expected)) return actual;
  if (expected && typeof expected === "object") {
    return Object.fromEntries(
      Object.entries(expected).map(([key, value]) => [
        key,
        projectExpectedFields(actual?.[key], value),
      ]),
    );
  }
  return actual;
};

export const expectedRules = () => structuredClone(policy.rules);

const applyCloudflareResponseDefaults = (actual, expected) => {
  const normalized = structuredClone(actual);
  // Free cannot exclude cached requests from rate counting. Cloudflare accepts an explicit false on
  // creation but omits requests_to_origin from the returned object; absent therefore represents the
  // same forced setting for this Free-only profile. An explicit true must continue to fail the audit.
  if (
    policy.cloudflare_plan === "free" &&
    expected.ratelimit?.requests_to_origin === false &&
    normalized?.ratelimit?.requests_to_origin === undefined
  ) {
    normalized.ratelimit.requests_to_origin = false;
  }
  return normalized;
};

export const validateRuleset = (ruleset) => {
  if (ruleset?.phase !== policy.phase || !Array.isArray(ruleset.rules)) {
    throw new Error("unexpected rate-limit entry-point response");
  }
  if (ruleset.rules.length !== policy.rules.length) {
    throw new Error(`expected exactly ${policy.rules.length} rate-limit rule`);
  }

  for (const expected of expectedRules()) {
    const matches = ruleset.rules.filter((rule) => rule.ref === expected.ref);
    if (matches.length !== 1) {
      throw new Error(`expected exactly one enabled rule ref=${expected.ref}`);
    }

    const normalized = applyCloudflareResponseDefaults(matches[0], expected);
    const actual = projectExpectedFields(normalized, expected);
    if (!isDeepStrictEqual(actual, expected)) {
      throw new Error(`deployed rule differs from the required policy ref=${expected.ref}`);
    }
  }
};

const parseSuccessfulPayload = async (response) => {
  try {
    const payload = await response.json();
    if (payload?.success !== true) throw new Error("failed result");
    return payload;
  } catch {
    throw new RateLimitAuditError(
      "Cloudflare Rulesets API returned an invalid or failed result",
      AUDIT_EXIT.apiUnavailable,
    );
  }
};

export const auditRateLimitPolicy = async ({ env = process.env, fetchImpl = fetch } = {}) => {
  const zoneId = env.CLOUDFLARE_ZONE_ID || "";
  const apiToken = env.CLOUDFLARE_RULESETS_READ_TOKEN || "";

  if (!/^[0-9a-f]{32}$/.test(zoneId)) {
    throw new RateLimitAuditError("invalid Cloudflare zone id", AUDIT_EXIT.invalidConfiguration);
  }
  if (apiToken.length < 20) {
    throw new RateLimitAuditError(
      "missing Cloudflare Rulesets read token",
      AUDIT_EXIT.invalidConfiguration,
    );
  }

  let response;
  try {
    const entrypoint =
      `https://api.cloudflare.com/client/v4/zones/${zoneId}` +
      "/rulesets/phases/http_ratelimit/entrypoint";
    response = await fetchImpl(
      entrypoint,
      {
        headers: { authorization: `Bearer ${apiToken}`, accept: "application/json" },
        redirect: "error",
        signal: AbortSignal.timeout(15_000),
      },
    );
  } catch {
    throw new RateLimitAuditError(
      "Cloudflare Rulesets API was unavailable",
      AUDIT_EXIT.apiUnavailable,
    );
  }

  if (response.status === 404) {
    throw new RateLimitAuditError(
      "no http_ratelimit ruleset exists; run the one-time Free-plan provisioning procedure",
      AUDIT_EXIT.missingRuleset,
    );
  }
  if (response.status === 401 || response.status === 403) {
    throw new RateLimitAuditError(
      "Cloudflare rejected the zone or read-only Rulesets token",
      AUDIT_EXIT.accessDenied,
    );
  }
  if (!response.ok) {
    throw new RateLimitAuditError(
      "Cloudflare Rulesets API rejected the audit",
      AUDIT_EXIT.apiUnavailable,
    );
  }

  const payload = await parseSuccessfulPayload(response);
  try {
    validateRuleset(payload.result);
  } catch (error) {
    throw new RateLimitAuditError(error.message, AUDIT_EXIT.policyDrift);
  }

  return policy.rules.length;
};

const main = async () => {
  const ruleCount = await auditRateLimitPolicy();
  console.log(`Cloudflare Free-plan rate-limit policy passed rules=${ruleCount}`);
};

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await main();
  } catch (error) {
    const message =
      error instanceof RateLimitAuditError ? error.message : "unexpected local audit failure";
    console.error(`Cloudflare rate-limit policy failed: ${message}`);
    process.exitCode = error instanceof RateLimitAuditError ? error.exitCode : 1;
  }
}
