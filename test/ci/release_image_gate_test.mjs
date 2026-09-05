// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const release = readFileSync(new URL("../../.github/workflows/release.yml", import.meta.url), "utf8");
const deploy = readFileSync(new URL("../../ops/roles/deploy/tasks/main.yml", import.meta.url), "utf8");
const dockerfile = readFileSync(new URL("../../Dockerfile", import.meta.url), "utf8");
const mixProject = readFileSync(new URL("../../mix.exs", import.meta.url), "utf8");

assert.match(release, /group: release\n/);
assert.match(release, /version=\$\([.]github\/scripts\/next-release-version[.]sh "\$REVISION"\)/);
assert.match(release, /needs: \[identity, source, publish\]/);
assert.match(release, /gh release create "\$tag"/);
assert.equal(
  release.match(/^      contents: write$/gm)?.length,
  1,
  "only the final release-recording job may write repository contents",
);
assert.match(release, /org\.opencontainers\.image\.version=\$\{\{ steps\.identity\.outputs\.version \}\}/);
assert.match(release, /BURNERPAD_VERSION=\$\{\{ steps\.identity\.outputs\.version \}\}/);
assert.match(dockerfile, /ARG BURNERPAD_VERSION=0[.]0[.]0/);
assert.match(mixProject, /System[.]get_env\("BURNERPAD_VERSION", "0[.]0[.]0"\)/);
assert.doesNotMatch(release + dockerfile + mixProject, /1[.]0[.]1/);

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
assert.ok(
  release.indexOf("- name: Create the immutable release tag and GitHub Release") >
    release.indexOf("- name: Promote the approved digest to the main alias without rebuilding"),
  "release tag must be recorded only after image approval and promotion",
);

const sourceEvidenceSection = release.slice(
  release.indexOf("- name: Verify and collect the source release evidence"),
  release.indexOf("- name: Archive the source release, SPDX SBOM, and attestation"),
);
assert.match(sourceEvidenceSection, /gh attestation verify "\$archive"/);
assert.match(sourceEvidenceSection, /--bundle "\$ATTESTATION_BUNDLE"/);
assert.match(sourceEvidenceSection, /--predicate-type https:\/\/spdx\.dev\/Document\/v2\.3/);
assert.match(
  sourceEvidenceSection,
  /--cert-identity "https:\/\/github\.com\/\$GITHUB_REPOSITORY\/\.github\/workflows\/release\.yml@refs\/heads\/main"/,
);
assert.match(sourceEvidenceSection, /--deny-self-hosted-runners/);

for (const source of [release, deploy]) {
  assert.match(source, /--predicate-type https:\/\/burnerpad\.io\/attestations\/trivy\/v1/);
}

assert.match(deploy, /Verify keyless Sigstore signatures/);
assert.match(deploy, /Verify GitHub build-provenance attestations/);
assert.match(deploy, /Verify GitHub vulnerability-scan attestations/);

console.log("release image gate tests passed");
