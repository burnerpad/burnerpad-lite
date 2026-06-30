// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU
//
// Unit tests for the DOM-free `Core` of crypto-app.js — the security-relevant string/parse logic (link
// display, word canonicalization, paste parsing/cap, passphrase strength). Requiring the file under Node
// returns `Core` and never runs the browser DOM code: the `module.exports` guard returns first. Run with
// `mix test.core` (or `node --test test/crypto/core_test.cjs`). Needs Node >= 20.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const Core = require("../../priv/static/crypto/crypto-app.js");

test("displayUrl strips scheme + leading www for display (the full URL is copied separately)", () => {
  assert.equal(Core.displayUrl("https://burnerpad.io/s/ABC123"), "burnerpad.io/s/ABC123");
  assert.equal(Core.displayUrl("http://www.burnerpad.io/s/ABC123"), "burnerpad.io/s/ABC123");
  assert.equal(Core.displayUrl("https://www.example.org/s/x"), "example.org/s/x");
  assert.equal(Core.displayUrl("burnerpad.io/s/x"), "burnerpad.io/s/x"); // already clean
  assert.equal(Core.displayUrl("https://host/www.keep"), "host/www.keep"); // only a LEADING www. is dropped
});

test("canonWord trims + lowercases to the key-derivation form", () => {
  assert.equal(Core.canonWord("  Hello "), "hello");
  assert.equal(Core.canonWord("WORD"), "word");
});

test("parsePaste splits on any whitespace, canonicalizes, and ignores empties", () => {
  assert.deepEqual(Core.parsePaste("alpha Bravo  charlie", 64), ["alpha", "bravo", "charlie"]);
  assert.deepEqual(Core.parsePaste("  one\ntwo\tthree  ", 64), ["one", "two", "three"]);
  assert.deepEqual(Core.parsePaste("", 64), []);
});

test("parsePaste caps a runaway paste (the DOM-flood defense)", () => {
  const many = Array.from({ length: 200 }, (_, i) => "tok" + i).join(" ");
  assert.equal(Core.parsePaste(many, 64).length, 64); // 200 distinct words → capped to 64
  assert.equal(Core.parsePaste(many, 0).length, 200); // no cap → all tokens
});

test("strength: below the floor is 'bad' with an add-N message, no warning", () => {
  const s = Core.strength(5, 5, 7);
  assert.equal(s.cls, "strength bad");
  assert.equal(s.warn, false);
  assert.match(s.label, /add 2 more/);
});

test("strength: 7 pure generated words is 'very strong', no warning", () => {
  const s = Core.strength(7, 7, 7);
  assert.equal(s.cls, "strength ok");
  assert.equal(s.warn, false);
  assert.match(s.label, /very strong/);
});

test("strength: extra hand-picked words on top of the full random core is 'mixed'", () => {
  const s = Core.strength(9, 7, 7); // 7 generated + 2 custom — custom only ADDS entropy
  assert.equal(s.cls, "strength ok");
  assert.equal(s.warn, false);
  assert.match(s.label, /mixed/);
});

test("strength: removing a random word below the floor is 'weak' and warns", () => {
  const s = Core.strength(7, 5, 7); // 7 words, but only 5 from the random core
  assert.equal(s.cls, "strength weak");
  assert.equal(s.warn, true);
  assert.match(s.label, /weaker/);
});
