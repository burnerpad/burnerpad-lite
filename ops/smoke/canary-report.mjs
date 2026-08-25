// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import { appendFileSync } from "node:fs";

const revisionPattern = /^[0-9a-f]{40}$/;
const versionPattern = /^[0-9A-Za-z][0-9A-Za-z.-]{0,63}\+([0-9a-f]{40})$/;
const checks = new Set(["edge_contract", "end_to_end"]);
const stages = new Set([
  "startup",
  "configuration",
  "release_identity",
  "readiness",
  "https_redirect",
  "minimum_tls",
  "html_headers",
  "sri_assets",
  "sri_revalidation",
  "api_cache",
  "health_cache",
  "readiness_cache",
  "client_ip",
  "client_ip_trace",
  "client_ip_baseline",
  "client_ip_spoof",
  "encrypt",
  "create",
  "reveal",
  "decrypt",
  "at_most_once",
  "passed",
]);

const defaultOutput = (fields) => {
  const outputFile = process.env.GITHUB_OUTPUT;
  if (!outputFile) return;
  appendFileSync(outputFile, Object.entries(fields).map(([key, value]) => `${key}=${value}\n`).join(""));
};

/**
 * Keep public-canary reporting behind a narrow interface. Only fixed stage/check labels and validated
 * release revisions can cross this boundary; caught errors and transaction material never do.
 */
export const createCanaryReporter = ({ check, logger = console, writeOutput = defaultOutput }) => {
  if (!checks.has(check)) throw new Error("invalid canary check");

  let stage = "startup";
  let expectedRevision = "";
  let observedRevision = "";

  const fields = (status, reportedStage) => {
    const release = observedRevision || expectedRevision || "unavailable";
    const releaseSource = observedRevision ? "observed" : expectedRevision ? "expected" : "unavailable";

    return {
      status,
      check,
      stage: reportedStage,
      release,
      release_source: releaseSource,
      expected_release: expectedRevision || "unavailable",
    };
  };

  return {
    setStage(nextStage) {
      if (!stages.has(nextStage)) throw new Error("invalid canary stage");
      stage = nextStage;
    },

    configureExpectedRevision(rawRevision, { required = false } = {}) {
      if (rawRevision === "") {
        if (required) throw new Error("expected revision is required");
        return;
      }
      if (!revisionPattern.test(rawRevision)) throw new Error("expected revision is invalid");
      expectedRevision = rawRevision;
    },

    observeStats(stats) {
      const match = typeof stats?.version === "string" ? versionPattern.exec(stats.version) : null;
      if (!match) throw new Error("public release identity is invalid");
      observedRevision = match[1];
      if (expectedRevision && observedRevision !== expectedRevision) {
        throw new Error("public release does not match the expected revision");
      }
      return observedRevision;
    },

    succeeded() {
      const result = fields("success", "passed");
      logger.log(`Burnerpad ${check} canary passed release=${result.release}`);
      writeOutput(result);
    },

    failed() {
      const result = fields("failure", stage);
      logger.error(
        `Burnerpad ${check} canary failed stage=${result.stage} release=${result.release} ` +
          `release_source=${result.release_source}`,
      );
      writeOutput(result);
    },
  };
};
