// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import { readFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";
import { pathToFileURL } from "node:url";

const policy = JSON.parse(readFileSync(new URL("./rate-limit-policy.json", import.meta.url), "utf8"));

const substituteHost = (value, host) => {
  if (typeof value === "string") return value.replaceAll("{{host}}", host);
  if (Array.isArray(value)) return value.map((item) => substituteHost(item, host));
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, substituteHost(item, host)]));
  }
  return value;
};

const projectExpectedFields = (actual, expected) => {
  if (Array.isArray(expected)) return actual;
  if (expected && typeof expected === "object") {
    return Object.fromEntries(
      Object.entries(expected).map(([key, value]) => [key, projectExpectedFields(actual?.[key], value)]),
    );
  }
  return actual;
};

export const expectedRules = (host) => substituteHost(policy.rules, host);

export const validateRuleset = (ruleset, host) => {
  if (ruleset?.phase !== policy.phase || !Array.isArray(ruleset.rules)) {
    throw new Error("unexpected rate-limit entry-point response");
  }

  for (const expected of expectedRules(host)) {
    const matches = ruleset.rules.filter((rule) => rule.ref === expected.ref);
    if (matches.length !== 1) throw new Error(`expected exactly one enabled rule ref=${expected.ref}`);

    const actual = projectExpectedFields(matches[0], expected);
    if (!isDeepStrictEqual(actual, expected)) {
      throw new Error(`deployed rule differs from the required policy ref=${expected.ref}`);
    }
  }
};

const main = async () => {
  const zoneId = process.env.CLOUDFLARE_ZONE_ID || "";
  const apiToken = process.env.CLOUDFLARE_RULESETS_READ_TOKEN || "";
  const origin = process.env.BURNERPAD_BASE_URL || "";
  const parsed = new URL(origin);

  if (!/^[0-9a-f]{32}$/.test(zoneId)) throw new Error("invalid Cloudflare zone id");
  if (apiToken.length < 20) throw new Error("missing Cloudflare Rulesets read token");
  if (parsed.protocol !== "https:" || parsed.pathname !== "/" || parsed.search || parsed.hash) {
    throw new Error("BURNERPAD_BASE_URL must be an HTTPS origin without a path");
  }

  const response = await fetch(
    `https://api.cloudflare.com/client/v4/zones/${zoneId}/rulesets/phases/http_ratelimit/entrypoint`,
    {
      headers: { authorization: `Bearer ${apiToken}`, accept: "application/json" },
      redirect: "error",
      signal: AbortSignal.timeout(15_000),
    },
  );
  if (!response.ok) throw new Error("Cloudflare Rulesets API rejected the audit");

  const payload = await response.json();
  if (payload?.success !== true) throw new Error("Cloudflare Rulesets API returned a failed result");
  validateRuleset(payload.result, parsed.hostname);
  console.log(`Cloudflare rate-limit policy passed rules=${policy.rules.length}`);
};

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await main();
  } catch (error) {
    console.error(`Cloudflare rate-limit policy failed: ${error.message}`);
    process.exitCode = 1;
  }
}
