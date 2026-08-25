// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import assert from "node:assert/strict";
import test from "node:test";
import {
  requireDynamicNoStore,
  requireStaticRevalidation,
} from "../../ops/smoke/edge-cache-contract.mjs";

test("dynamic cache checks require no-store and reject an edge hit", () => {
  assert.doesNotThrow(() => requireDynamicNoStore(new Response("ready", {
    status: 200,
    headers: { "cache-control": "private, no-store", "cf-cache-status": "DYNAMIC" },
  })));

  assert.throws(() => requireDynamicNoStore(new Response("ready", { status: 200 })), /cacheable/);
  assert.throws(() => requireDynamicNoStore(new Response("ready", {
    status: 200,
    headers: { "cache-control": "no-store", "cf-cache-status": "HIT" },
  })), /edge cache/);
});

test("static cache checks require a matching 304 ETag", () => {
  const initial = new Response("asset", { status: 200, headers: { etag: '"asset-v1"' } });
  assert.doesNotThrow(() => requireStaticRevalidation(
    initial,
    new Response(null, { status: 304, headers: { etag: '"asset-v1"' } }),
  ));

  assert.throws(() => requireStaticRevalidation(new Response("asset"), new Response(null, { status: 304 })));
  assert.throws(() => requireStaticRevalidation(
    initial,
    new Response("asset", { status: 200, headers: { etag: '"asset-v1"' } }),
  ));
  assert.throws(() => requireStaticRevalidation(
    initial,
    new Response(null, { status: 304, headers: { etag: '"asset-v2"' } }),
  ));
});

test("static revalidation accepts Cloudflare weakening a compressed response ETag", () => {
  const compressed = new Response("asset", { headers: { etag: 'W/"asset-v1"' } });
  const revalidated = new Response(null, { status: 304, headers: { etag: '"asset-v1"' } });

  assert.doesNotThrow(() => requireStaticRevalidation(compressed, revalidated));
});
