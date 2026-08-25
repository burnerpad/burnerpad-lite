// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import assert from "node:assert/strict";
import test from "node:test";
import {
  AUDIT_EXIT,
  auditRateLimitPolicy,
  expectedRules,
  policy,
  validateRuleset,
} from "../../ops/cloudflare/audit-rate-limit-policy.mjs";
import { provisionRateLimitPolicy } from "../../ops/cloudflare/provision-rate-limit-policy.mjs";

const zoneId = "0123456789abcdef0123456789abcdef";
const token = "test-token-longer-than-twenty-characters";
const configured = () => ({ phase: "http_ratelimit", rules: expectedRules() });
const rule = (ruleset) => ruleset.rules[0];
const response = (status, payload = {}) => ({
  ok: status >= 200 && status < 300,
  status,
  json: async () => payload,
});
const rejectsPolicy = (mutate) => {
  const ruleset = configured();
  mutate(ruleset);
  assert.throws(() => validateRuleset(ruleset));
};

test("the source of truth is compatible with Cloudflare Free", () => {
  assert.equal(policy.cloudflare_plan, "free");
  assert.equal(policy.rules.length, 1);
  assert.deepEqual(rule(configured()).ratelimit.characteristics, ["cf.colo.id", "ip.src"]);
  assert.equal(rule(configured()).ratelimit.period, 10);
  assert.equal(rule(configured()).ratelimit.mitigation_timeout, 10);
  assert.equal(rule(configured()).ratelimit.requests_to_origin, false);
  assert.doesNotMatch(rule(configured()).expression, /http\.host|http\.request\.method/);
});

test("the exact combined health and static edge policy passes", () => {
  assert.doesNotThrow(() => validateRuleset(configured()));
});

test("the audit accepts Cloudflare omitting Free's forced cached-request setting", () => {
  const ruleset = configured();
  delete rule(ruleset).ratelimit.requests_to_origin;
  assert.doesNotThrow(() => validateRuleset(ruleset));
});

test("the audit rejects an extra, removed, or disabled rule", () => {
  rejectsPolicy((ruleset) => ruleset.rules.push({ ref: "unrelated_zone_rule", enabled: true }));
  rejectsPolicy((ruleset) => ruleset.rules.pop());
  rejectsPolicy((ruleset) => {
    rule(ruleset).enabled = false;
  });
});

test("the audit rejects weaker thresholds or failure behavior", () => {
  rejectsPolicy((ruleset) => {
    rule(ruleset).ratelimit.requests_per_period = 101;
  });
  rejectsPolicy((ruleset) => {
    rule(ruleset).ratelimit.mitigation_timeout = 0;
  });
  rejectsPolicy((ruleset) => {
    rule(ruleset).action = "challenge";
  });
});

test("the audit rejects cache-busting or expression bypasses", () => {
  rejectsPolicy((ruleset) => {
    rule(ruleset).ratelimit.requests_to_origin = true;
  });
  rejectsPolicy((ruleset) => {
    rule(ruleset).expression += " or http.request.uri.path eq \"/\"";
  });
});

test("the live audit classifies a missing entry point without exposing API details", async () => {
  await assert.rejects(
    auditRateLimitPolicy({
      env: { CLOUDFLARE_ZONE_ID: zoneId, CLOUDFLARE_RULESETS_READ_TOKEN: token },
      fetchImpl: async () => response(404),
    }),
    (error) => {
      assert.equal(error.exitCode, AUDIT_EXIT.missingRuleset);
      assert.match(error.message, /one-time Free-plan provisioning/);
      return true;
    },
  );
});

test("the live audit classifies access denial and policy drift", async () => {
  await assert.rejects(
    auditRateLimitPolicy({
      env: { CLOUDFLARE_ZONE_ID: zoneId, CLOUDFLARE_RULESETS_READ_TOKEN: token },
      fetchImpl: async () => response(403),
    }),
    (error) => error.exitCode === AUDIT_EXIT.accessDenied,
  );

  const drifted = configured();
  rule(drifted).ratelimit.requests_per_period += 1;
  await assert.rejects(
    auditRateLimitPolicy({
      env: { CLOUDFLARE_ZONE_ID: zoneId, CLOUDFLARE_RULESETS_READ_TOKEN: token },
      fetchImpl: async () => response(200, { success: true, result: drifted }),
    }),
    (error) => error.exitCode === AUDIT_EXIT.policyDrift,
  );
});

test("provisioning creates the exact policy only when no entry point exists", async () => {
  const calls = [];
  const created = configured();
  const result = await provisionRateLimitPolicy({
    env: { CLOUDFLARE_ZONE_ID: zoneId, CLOUDFLARE_RULESETS_WRITE_TOKEN: token },
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return calls.length === 1
        ? response(404)
        : response(200, { success: true, result: created });
    },
  });

  assert.equal(result, "created");
  assert.equal(calls.length, 2);
  assert.equal(calls[1].options.method, "POST");
  assert.deepEqual(JSON.parse(calls[1].options.body).rules, expectedRules());
});

test("provisioning is idempotent and refuses to overwrite drift", async () => {
  const cloudflareNormalized = configured();
  delete rule(cloudflareNormalized).ratelimit.requests_to_origin;
  const alreadyConfigured = await provisionRateLimitPolicy({
    env: { CLOUDFLARE_ZONE_ID: zoneId, CLOUDFLARE_RULESETS_WRITE_TOKEN: token },
    fetchImpl: async () => response(200, { success: true, result: cloudflareNormalized }),
  });
  assert.equal(alreadyConfigured, "already-configured");

  const drifted = configured();
  rule(drifted).enabled = false;
  await assert.rejects(
    provisionRateLimitPolicy({
      env: { CLOUDFLARE_ZONE_ID: zoneId, CLOUDFLARE_RULESETS_WRITE_TOKEN: token },
      fetchImpl: async () => response(200, { success: true, result: drifted }),
    }),
    /refusing to overwrite/,
  );
});
