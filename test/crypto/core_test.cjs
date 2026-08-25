// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU
//
// Unit tests for the DOM-free `Core` of crypto-app.js — the security-relevant string/parse logic (link
// display, word canonicalization, paste parsing/cap, passphrase strength). Requiring the file under Node
// returns `Core` and never runs the browser DOM code: the `module.exports` guard returns first. Run with
// `mix test.core` (or `node --test test/crypto/core_test.cjs`). Needs Node >= 20.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
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

test("parsePaste never silently truncates a credential", () => {
  const many = Array.from({ length: 200 }, (_, i) => "tok" + i).join(" ");
  assert.equal(Core.parsePaste(many).length, 200);
});

test("validatePaste rejects unsafe limits and duplicates without changing tokens", () => {
  assert.deepEqual(Core.validatePaste("alpha bravo", 64, 1024, 32), { ok: true, tokens: ["alpha", "bravo"] });
  assert.equal(Core.validatePaste("alpha alpha", 64, 1024, 32).error, "duplicate");
  assert.equal(Core.validatePaste("x ".repeat(65), 64, 1024, 32).error, "too_many");
  assert.equal(Core.validatePaste("x".repeat(33) + " y", 64, 1024, 32).error, "token_too_long");
  assert.equal(Core.validatePaste("x".repeat(1025), 64, 1024, 2048).error, "too_large");
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

test("text encoding preserves exact well-formed Unicode without normalization or BOM stripping", () => {
  const text = "\uFEFFemoji 🧪 · CJK 秘密 · decomposed e\u0301";
  const bytes = Core.encodeText(text);

  assert.equal(Core.decodeText(bytes), text);
  assert.notEqual(Core.decodeText(bytes), text.normalize("NFC"));
  assert.equal(Core.decodeText(bytes).charCodeAt(0), 0xFEFF);
});

test("text encoding rejects unpaired UTF-16 surrogates instead of replacing them", () => {
  for (const malformed of ["before\uD800after", "before\uDC00after", "\uD800"]) {
    assert.equal(Core.isWellFormedText(malformed), false);
    assert.throws(() => Core.encodeText(malformed), /invalid_unicode/);
  }
  assert.equal(Core.isWellFormedText("paired \uD83E\uDDEA"), true);
});

test("text decoding rejects malformed UTF-8 instead of inserting replacement characters", () => {
  assert.throws(() => Core.decodeText(Uint8Array.from([0xC3, 0x28])), /invalid_utf8/);
});

test("UTF-8 byte accounting is exact at and over the plaintext limit", () => {
  const max = 65536 - 45;
  assert.equal(Core.encodeText("a".repeat(max)).length, max);
  assert.equal(Core.encodeText("🧪".repeat(Math.floor(max / 4))).length, Math.floor(max / 4) * 4);
  assert.equal(Core.encodeText("a".repeat(max + 1)).length, max + 1);
});

test("durationLabel displays the server-returned effective TTL", () => {
  assert.equal(Core.durationLabel(60), "1m");
  assert.equal(Core.durationLabel(3600), "1h");
  assert.equal(Core.durationLabel(61), "61s");
});

test("reveal claim state owns transitions, concurrency, and ciphertext zeroization", () => {
  const claim = Core.revealClaim();
  assert.deepEqual(claim.view(), { phase: "unclaimed", active: false, hasCiphertext: false });

  assert.equal(claim.advance("begin"), true);
  assert.equal(claim.advance("begin"), false);
  const held = Uint8Array.from([1, 2, 3]);
  claim.advance("hold", held);
  assert.deepEqual(claim.view(), { phase: "held", active: true, hasCiphertext: true });
  assert.equal(claim.ciphertext(), held);
  claim.advance("finish");

  assert.equal(claim.advance("begin"), true);
  claim.advance("unavailable");
  assert.deepEqual(Array.from(held), [0, 0, 0]);
  claim.advance("finish");
  assert.deepEqual(claim.view(), { phase: "unavailable", active: false, hasCiphertext: false });
  assert.equal(claim.advance("begin"), false);
});

test("unknown reveal state permits only a deliberate next begin and purge is terminal", () => {
  const claim = Core.revealClaim();
  claim.advance("begin");
  claim.advance("unknown");
  claim.advance("finish");
  assert.deepEqual(claim.view(), { phase: "unknown", active: false, hasCiphertext: false });
  assert.equal(claim.advance("begin"), true);

  const held = Uint8Array.from([9, 8, 7]);
  claim.advance("hold", held);
  claim.advance("purge");
  assert.deepEqual(Array.from(held), [0, 0, 0]);
  assert.deepEqual(claim.view(), { phase: "unavailable", active: false, hasCiphertext: false });
  assert.equal(claim.advance("begin"), false);
  assert.equal(claim.advance("unknown"), false);
  const rejected = Uint8Array.from([6, 5, 4]);
  assert.equal(claim.advance("hold", rejected), false);
  assert.deepEqual(Array.from(rejected), [0, 0, 0]);
  assert.deepEqual(claim.view(), { phase: "unavailable", active: false, hasCiphertext: false });
  assert.throws(() => claim.advance("not-an-event"), /invalid_reveal_transition/);
});

test("the embedded phrase list has 1296 distinct words and three-character prefixes", () => {
  const source = readFileSync(require.resolve("../../priv/static/crypto/crypto-app.js"), "utf8");
  const match = source.match(/var WORDS = \("([^"]+)"\)\.split\(" "\)/);
  assert.ok(match, "embedded WORDS declaration found");
  const words = match[1].split(" ");
  assert.equal(words.length, 1296);
  assert.equal(new Set(words).size, 1296);
  assert.equal(new Set(words.map((word) => word.slice(0, 3))).size, 1296);
});
