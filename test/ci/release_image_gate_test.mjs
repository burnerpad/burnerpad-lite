// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const release = readFileSync(new URL("../../.github/workflows/release.yml", import.meta.url), "utf8");
const deploy = readFileSync(new URL("../../ops/roles/deploy/tasks/main.yml", import.meta.url), "utf8");
const version = readFileSync(new URL("../../VERSION", import.meta.url), "utf8").trim();
const dockerfile = readFileSync(new URL("../../Dockerfile", import.meta.url), "utf8");

assert.equal(version, "1.0.0");
assert.match(release, /org\.opencontainers\.image\.version=\$\{\{ steps\.identity\.outputs\.version \}\}/);
assert.match(release, /BURNERPAD_VERSION=\$\{\{ steps\.identity\.outputs\.version \}\}/);
assert.match(dockerfile, new RegExp(`ARG BURNERPAD_VERSION=${version.replaceAll(".", "\\.")}`));

const orderedReleaseSteps = [
  "- name: Build and publish ${{ matrix.version }} image",
  "- name: Scan the exact published digest for high and critical vulnerabilities",
  "- name: Attach the passed vulnerability-scan attestation",
  "- name: Attach GitHub build-provenance attestation",
  "- name: Add a keyless Sigstore signature",
  "- name: Verify the just-published signature",
  "- name: Promote the approved digest to the main alias without rebuilding",
];

let previous = -1;
for (const step of orderedReleaseSteps) {
  const position = release.indexOf(step);
  assert.notEqual(position, -1, `release workflow is missing: ${step}`);
  assert.ok(position > previous, `release approval step is out of order: ${step}`);
  previous = position;
}

assert.match(release, /--skip-version-check "\$IMAGE@\$DIGEST"/);
assert.match(release, /subject-digest: \$\{\{ steps\.build\.outputs\.digest \}\}/);
assert.match(release, /cosign sign --yes "\$IMAGE@\$DIGEST"/);

const buildSection = release.slice(
  release.indexOf("- name: Build and publish ${{ matrix.version }} image"),
  release.indexOf("- name: Pull the exact published digest for scanning"),
);
assert.doesNotMatch(buildSection, /:main/);
assert.match(release, /imagetools create --prefer-index=false --tag "\$IMAGE:main"/);
assert.match(release, /test "\$promoted_digest" = "\$DIGEST"/);

for (const source of [release, deploy]) {
  assert.match(source, /--predicate-type https:\/\/burnerpad\.io\/attestations\/trivy\/v1/);
}

assert.match(deploy, /Verify keyless Sigstore signatures/);
assert.match(deploy, /Verify GitHub build-provenance attestations/);
assert.match(deploy, /Verify GitHub vulnerability-scan attestations/);

console.log("release image gate tests passed");
