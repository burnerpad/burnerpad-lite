// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import assert from "node:assert/strict";
import test from "node:test";
import { waitUntilReady } from "../../ops/smoke/readiness.mjs";

const response = (status, body) => new Response(body, {
  status,
  headers: { "cache-control": "no-store" },
});

test("readiness polling reaches a fresh target without waiting on the wall clock", async () => {
  let nowMs = 0;
  let attempts = 0;

  const ready = await waitUntilReady({
    timeoutMs: 1_000,
    now: () => nowMs,
    sleep: async (delayMs) => { nowMs += delayMs; },
    request: async () => {
      attempts += 1;
      return attempts < 3 ? response(503, "not ready") : response(200, "ready");
    },
  });

  assert.equal(ready, true);
  assert.equal(attempts, 3);
  assert.equal(nowMs, 400);
});

test("readiness polling exhausts its exact budget without waiting on the wall clock", async () => {
  let nowMs = 0;
  const delays = [];

  const ready = await waitUntilReady({
    timeoutMs: 450,
    now: () => nowMs,
    sleep: async (delayMs) => {
      delays.push(delayMs);
      nowMs += delayMs;
    },
    request: async () => response(503, "not ready"),
  });

  assert.equal(ready, false);
  assert.deepEqual(delays, [200, 200, 50]);
  assert.equal(nowMs, 450);
});

test("readiness polling tolerates a connection refusal inside its budget", async () => {
  let nowMs = 0;
  let attempts = 0;

  const ready = await waitUntilReady({
    timeoutMs: 500,
    now: () => nowMs,
    sleep: async (delayMs) => { nowMs += delayMs; },
    request: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("connection refused");
      return response(200, "ready");
    },
  });

  assert.equal(ready, true);
  assert.equal(attempts, 2);
});
