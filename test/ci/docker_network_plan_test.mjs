// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const checker = fileURLToPath(new URL("../../ops/check-docker-network-plan.mjs", import.meta.url));

const network = ({ name, subnet, project = "", logicalName = "" }) => ({
  Name: name,
  IPAM: { Config: [{ Subnet: subnet }] },
  Labels: {
    "com.docker.compose.project": project,
    "com.docker.compose.network": logicalName
  }
});

const run = (subnet, inventory) =>
  spawnSync(process.execPath, [checker, subnet, "burnerpad", "backend"], {
    input: JSON.stringify(inventory),
    encoding: "utf8",
    env: { PATH: process.env.PATH ?? "" }
  });

const legacyInventory = [
  network({
    name: "burnerpad_internal",
    subnet: "172.28.0.0/16",
    project: "burnerpad",
    logicalName: "internal"
  })
];

test("reproduces the pre-1.0 to v1 backend subnet collision", () => {
  const result = run("172.28.0.0/16", legacyInventory);

  assert.equal(result.status, 10);
  assert.equal(result.stdout, "");
  assert.equal(
    result.stderr,
    "Docker backend subnet overlaps network=burnerpad_internal allocated=172.28.0.0/16.\n"
  );
});

test("the v1 migration subnet can coexist with the legacy network", () => {
  const result = run("172.29.0.0/29", legacyInventory);

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "Docker backend subnet is available target=172.29.0.0/29.\n");
  assert.equal(result.stderr, "");
});

test("allows the exact backend network owned by this Compose project on redeploy", () => {
  const inventory = [
    network({
      name: "burnerpad_backend",
      subnet: "172.29.0.0/29",
      project: "burnerpad",
      logicalName: "backend"
    })
  ];
  const result = run("172.29.0.0/29", inventory);

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "Docker backend subnet is reusable target=172.29.0.0/29.\n");
});

test("rejects overlap with a differently owned Docker network", () => {
  const inventory = [network({ name: "other_default", subnet: "172.29.0.0/24" })];
  const result = run("172.29.0.0/29", inventory);

  assert.equal(result.status, 10);
  assert.match(result.stderr, /network=other_default allocated=172\.29\.0\.0\/24/);
});

for (const [label, subnet, inventory] of [
  ["malformed Docker inventory", "172.29.0.0/29", "not-json"],
  ["a non-array Docker inventory", "172.29.0.0/29", {}],
  ["an invalid target subnet", "not-a-cidr", []],
  ["a noncanonical target subnet", "172.29.0.1/29", []],
  ["a public target subnet", "203.0.113.0/29", []],
  ["a backend subnet too small for Docker", "172.29.0.0/30", []]
]) {
  test(`fails closed for ${label}`, () => {
    const input = typeof inventory === "string" ? inventory : JSON.stringify(inventory);
    const result = spawnSync(process.execPath, [checker, subnet, "burnerpad", "backend"], {
      input,
      encoding: "utf8",
      env: { PATH: process.env.PATH ?? "" }
    });

    assert.equal(result.status, 2);
    assert.equal(result.stdout, "");
    assert.equal(result.stderr, "Unable to validate the Docker backend network plan.\n");
  });
}
