// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import test from "node:test";

const parser = fileURLToPath(new URL("../../ops/extract-resident-count.mjs", import.meta.url));
const deployTasks = fileURLToPath(new URL("../../ops/roles/deploy/tasks/main.yml", import.meta.url));

const run = (input) =>
  spawnSync(process.execPath, [parser], {
    input,
    encoding: "utf8",
    env: { PATH: process.env.PATH ?? "" }
  });

test("accepts the deployed 0.1.0 legacy stored counter", () => {
  const result = run('{"stored":0,"version":"0.1.0+59f06a2"}');

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "0\n");
  assert.equal(result.stderr, "");
});

test("preserves a nonzero legacy count for the destructive-replacement prompt", () => {
  const result = run('{"stored":3,"version":"0.1.0+59f06a2"}');

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "3\n");
  assert.equal(result.stderr, "");
});

test("accepts the current resident counter", () => {
  const result = run('{"resident":7,"stored":7,"version":"1.0.0+abc"}');

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "7\n");
  assert.equal(result.stderr, "");
});

test("deployment probes stats through the BusyBox applet present in the release image", () => {
  const source = readFileSync(deployTasks, "utf8");
  const probes = [...source.matchAll(
    /^\s+(.+?) -qO- http:\/\/127\.0\.0\.1:4000\/api\/stats$/gm
  )].map((match) => match[1]);

  assert.deepEqual(probes, ["/bin/busybox wget", "/bin/busybox wget"]);
});

for (const [label, input] of [
  ["malformed JSON", "not-json"],
  ["an absent count", '{"version":"0.1.0+59f06a2"}'],
  ["a string count", '{"resident":"0"}'],
  ["a negative count", '{"resident":-1}'],
  ["a fractional count", '{"resident":1.5}'],
  ["an unsafe integer count", '{"resident":9007199254740992}'],
  ["a non-object response", "[]"]
]) {
  test(`rejects ${label} without echoing the response`, () => {
    const result = run(input);

    assert.notEqual(result.status, 0);
    assert.equal(result.stdout, "");
    assert.match(result.stderr, /^Unable to verify the resident ciphertext count\.\n$/);
    assert.ok(!result.stderr.includes(input));
  });
}
