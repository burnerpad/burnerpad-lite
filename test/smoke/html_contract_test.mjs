// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import assert from "node:assert/strict";
import test from "node:test";
import { hasUnsafeHtmlTransformation } from "../../ops/smoke/html-contract.mjs";

test("same-origin external scripts with empty bodies are safe", () => {
  assert.equal(
    hasUnsafeHtmlTransformation('<script src="/crypto/theme.js"></script>'),
    false,
  );
});

test("inline, malformed, and Cloudflare-transformed scripts are unsafe", () => {
  for (const html of [
    "<script>alert(1)</script>",
    '<script src="/crypto/theme.js">alert(1)</script>',
    '<script src="/crypto/theme.js">',
    '<script src="https://example.com/injected.js"></script>',
    '<script data-cfasync="false" src="/crypto/theme.js"></script>',
    '<script src="/cdn-cgi/scripts/rocket-loader.min.js"></script>',
  ]) {
    assert.equal(hasUnsafeHtmlTransformation(html), true, html);
  }
});
