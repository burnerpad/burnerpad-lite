// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import assert from "node:assert/strict";
import test from "node:test";
import { expectedRules, validateRuleset } from "../../ops/cloudflare/audit-rate-limit-policy.mjs";

const host = "burnerpad.example";
const configured = () => ({ phase: "http_ratelimit", rules: structuredClone(expectedRules(host)) });
const rule = (ruleset, ref) => ruleset.rules.find((candidate) => candidate.ref === ref);
const rejects = (mutate) => {
  const ruleset = configured();
  mutate(ruleset);
  assert.throws(() => validateRuleset(ruleset, host));
};

test("the exact health and static edge policy passes", () => {
  const ruleset = configured();
  ruleset.rules.push({ ref: "unrelated_zone_rule", enabled: true });
  assert.doesNotThrow(() => validateRuleset(ruleset, host));
});

test("the audit rejects a removed or disabled rule", () => {
  rejects((ruleset) => ruleset.rules.pop());
  rejects((ruleset) => {
    rule(ruleset, "burnerpad_health_readiness_v1").enabled = false;
  });
});

test("the audit rejects weaker thresholds or failure behavior", () => {
  rejects((ruleset) => {
    rule(ruleset, "burnerpad_health_readiness_v1").ratelimit.requests_per_period = 121;
  });
  rejects((ruleset) => {
    rule(ruleset, "burnerpad_static_v1").ratelimit.mitigation_timeout = 60;
  });
  rejects((ruleset) => {
    rule(ruleset, "burnerpad_static_v1").action = "challenge";
  });
});

test("the audit rejects cache-busting or expression bypasses", () => {
  rejects((ruleset) => {
    rule(ruleset, "burnerpad_static_v1").ratelimit.requests_to_origin = true;
  });
  rejects((ruleset) => {
    rule(ruleset, "burnerpad_health_readiness_v1").expression += " or ip.src in {192.0.2.1}";
  });
});
