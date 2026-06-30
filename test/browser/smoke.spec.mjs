// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import { test, expect } from "@playwright/test";

const rnd = () => Math.random().toString(36).slice(2);

// Chip text without the "×" remove glyph (removable chips include it; display-only result chips don't).
const chipTexts = async (locator) => (await locator.allTextContents()).map((s) => s.replace("×", "").trim());

// Add a word to a chip/autocomplete input: type the full word (which sorts first among its prefix
// matches), wait for the combobox to actually open (aria-expanded flips true once suggestions render —
// avoids racing the input handler), then press Enter to commit. List-locked — only real list words stick.
async function addWord(page, inputSel, word) {
  await page.fill(inputSel, word);
  await expect(page.locator(inputSel)).toHaveAttribute("aria-expanded", "true");
  await page.press(inputSel, "Enter");
}

// Passphrase-only flow (suite 0x02): words are GENERATED and shown on load; the link is key-less; the
// recipient rebuilds the phrase from the wordlist via autocomplete. Exercises generation, the key-less
// link, order-sensitivity, and the single-burn + local-retry (no second burn) logic.
test("passphrase create → key-less link → chip reveal (wrong order, then right)", async ({ page, context }) => {
  const secret = "psk secret " + rnd();

  await page.goto("/");
  await page.fill("#bp-input", secret);

  // the 7 generated words appear immediately as chips — no opt-in disclosure
  const chips = page.locator("#bp-pass-chips .chip");
  await expect(chips).toHaveCount(7);
  const words = await chipTexts(chips);
  expect(new Set(words).size).toBe(7); // distinct

  await page.getByRole("button", { name: "Encrypt & create link" }).click();

  await expect(page.locator("#bp-result")).toBeVisible();
  await expect(page.locator("#bp-create")).toBeHidden();
  // the result echoes the phrase as chips, and the link carries NO key
  await expect(page.locator("#bp-pass-out .chip")).toHaveCount(7);
  expect(await chipTexts(page.locator("#bp-pass-out .chip"))).toEqual(words);
  // the field DISPLAYS the link without its scheme; the full, navigable URL lives in data-full-url
  expect(await page.locator("#bp-link").inputValue()).not.toMatch(/^https?:\/\//);
  const link = await page.locator("#bp-link").getAttribute("data-full-url");
  expect(link).toMatch(/^https?:\/\//);
  expect(link).not.toContain("#");

  // recipient opens the key-less link in a fresh page
  const r = await context.newPage();
  await r.goto(link);
  await expect(r.locator("#bp-psk")).toBeVisible();
  await expect(r.locator("#bp-unsupported")).toBeHidden();
  await expect(r.locator("#bp-psk-field .tagrow")).toBeVisible(); // chips + input flow inline, like create
  // the reveal button is always active; its label invites words first, then flips to "Reveal & decrypt"
  await expect(r.locator("#bp-psk-reveal")).toBeEnabled();
  await expect(r.locator("#bp-psk-reveal")).toContainText(/enter at least 7 words/i);

  // wrong ORDER first (still real words — list-locked): the single reveal+burn happens, decryption fails
  for (const w of [...words].reverse()) await addWord(r, "#bp-psk-input", w);
  await expect(r.locator("#bp-psk-chips .chip")).toHaveCount(7);
  await expect(r.locator("#bp-psk-reveal")).toContainText(/reveal & decrypt/i);
  await r.locator("#bp-psk-reveal").click();
  await expect(r.locator("#bp-psk-error")).toContainText(/check the words/i);

  // fix the order locally — no second burn (the held blob is reused): clear, re-enter correctly, reveal
  for (let i = 0; i < 7; i++) await r.press("#bp-psk-input", "Backspace");
  await expect(r.locator("#bp-psk-chips .chip")).toHaveCount(0);
  for (const w of words) await addWord(r, "#bp-psk-input", w);
  await r.locator("#bp-psk-reveal").click();
  await expect(r.locator("#bp-secret")).toHaveText(secret);
  await expect(r.locator("#bp-copy-secret")).toBeVisible();
});

// Reveal convenience: the recipient can PASTE the whole space-separated phrase and every word becomes a
// chip — including the last one (no trailing space) — then it decrypts.
test("reveal: pasting the whole phrase makes a chip per word (incl. the last) and decrypts", async ({ page, context }) => {
  const secret = "paste-flow " + rnd();
  await page.goto("/");
  await page.fill("#bp-input", secret);
  const words = await chipTexts(page.locator("#bp-pass-chips .chip"));
  await page.getByRole("button", { name: "Encrypt & create link" }).click();
  await expect(page.locator("#bp-result")).toBeVisible();
  const link = await page.locator("#bp-link").getAttribute("data-full-url");

  const r = await context.newPage();
  await r.goto(link);
  // simulate a paste of the full phrase (space-joined, no trailing space) into the input
  await r.evaluate((t) => {
    const input = document.querySelector("#bp-psk-input");
    input.focus();
    const dt = new DataTransfer();
    dt.setData("text", t);
    input.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
  }, words.join(" "));
  await expect(r.locator("#bp-psk-chips .chip")).toHaveCount(7); // all 7, including the last word
  expect(await chipTexts(r.locator("#bp-psk-chips .chip"))).toEqual(words);
  await r.locator("#bp-psk-reveal").click();
  await expect(r.locator("#bp-secret")).toHaveText(secret);
});

test("reveal: a runaway paste is capped so it can't flood the DOM", async ({ page, context }) => {
  await page.goto("/");
  await page.fill("#bp-input", "cap-flow " + rnd());
  await page.getByRole("button", { name: "Encrypt & create link" }).click();
  await expect(page.locator("#bp-result")).toBeVisible();
  const link = await page.locator("#bp-link").getAttribute("data-full-url");

  const r = await context.newPage();
  await r.goto(link);
  // paste 200 DISTINCT tokens (so dedup can't bound it) — the handler must cap the chips at MAX_PASTE (64)
  const many = Array.from({ length: 200 }, (_, i) => "tok" + i).join(" ");
  await r.evaluate((t) => {
    const input = document.querySelector("#bp-psk-input");
    input.focus();
    const dt = new DataTransfer();
    dt.setData("text", t);
    input.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
  }, many);
  await expect(r.locator("#bp-psk-chips .chip")).toHaveCount(64);
});

// Create-side word controls: tapping a chip rerolls just that word; "choose my own words" opens a
// hand-pick autocomplete that builds a custom (7+ distinct) phrase, gated until it reaches 7.
test("tag field: button gating + strength meter (warns only when the random core drops)", async ({ page }) => {
  await page.goto("/");
  // the create button is ALWAYS active; its label invites a secret first, then flips on the first character
  await expect(page.locator("#bp-create-btn")).toBeEnabled();
  await expect(page.locator("#bp-create-btn")).toContainText(/add your secret/i);
  await page.fill("#bp-input", "controls " + rnd());

  const chips = page.locator("#bp-pass-chips .chip");
  const strength = page.locator("#bp-pass-strength");
  const warn = page.locator("#bp-pass-warn");

  await expect(chips).toHaveCount(7);
  await expect(page.locator("#bp-create-btn")).toBeEnabled();
  await expect(page.locator("#bp-create-btn")).toContainText("Encrypt & create link"); // flipped after input
  await expect(strength).toContainText(/very strong/i);
  await expect(warn).toBeHidden();

  // ADDING your own word on top of the full generated set stays strong — "mixed", green, no warning
  const gen = await chipTexts(chips);
  const extra = ["zucchini", "umbrella", "violin", "walrus", "tiger"].find((w) => !gen.includes(w));
  await addWord(page, "#bp-pass-input", extra);
  await expect(chips).toHaveCount(8);
  await expect(strength).toContainText(/mixed/i);
  await expect(strength).toHaveClass(/ok/);
  await expect(warn).toBeHidden();

  // REMOVING a generated word drops the random core below 7 → weaker + the warning, button still enabled
  await page.locator("#bp-pass-chips .chip .chip-x").first().click(); // first chip is a generated word
  await expect(chips).toHaveCount(7);
  await expect(warn).toBeVisible();
  await expect(strength).toContainText(/weaker/i);
  await expect(page.locator("#bp-create-btn")).toBeEnabled();

  // dropping below 7 total → red "add more"; the button stays active (gating is the strength cue + a
  // submit-time check), no longer a disabled state
  await page.locator("#bp-pass-chips .chip .chip-x").first().click();
  await expect(chips).toHaveCount(6);
  await expect(strength).toContainText(/add 1 more/i);
  await expect(strength).toHaveClass(/bad/);
  await expect(page.locator("#bp-create-btn")).toBeEnabled();

  // Regenerate restores a clean, strong generated set, and the secret encrypts
  await page.locator("#bp-pass-regen").click();
  await expect(chips).toHaveCount(7);
  await expect(strength).toContainText(/very strong/i);
  await expect(warn).toBeHidden();
  await page.getByRole("button", { name: "Encrypt & create link" }).click();
  await expect(page.locator("#bp-result")).toBeVisible();
});

// Manual word entry commits the highlighted suggestion on Space and Tab, not just Enter.
test("autocomplete commits a word on Space and on Tab", async ({ page }) => {
  await page.goto("/");
  await page.fill("#bp-input", "keys " + rnd());
  // clear the generated set so the adds below are deterministic
  for (let i = 0; i < 7; i++) await page.locator("#bp-pass-chips .chip .chip-x").first().click();
  await expect(page.locator("#bp-pass-chips .chip")).toHaveCount(0);

  // Space commits the highlighted word (and does not leave a literal space in the field)
  await page.fill("#bp-pass-input", "tiger");
  await expect(page.locator("#bp-pass-input")).toHaveAttribute("aria-expanded", "true");
  await page.press("#bp-pass-input", "Space");
  await expect(page.locator("#bp-pass-chips .chip")).toHaveCount(1);
  await expect(page.locator("#bp-pass-chips .chip").first()).toContainText("tiger");
  await expect(page.locator("#bp-pass-input")).toHaveValue("");

  // Tab commits too, keeping focus in the field for the next word
  await page.fill("#bp-pass-input", "cactus");
  await expect(page.locator("#bp-pass-input")).toHaveAttribute("aria-expanded", "true");
  await page.press("#bp-pass-input", "Tab");
  await expect(page.locator("#bp-pass-chips .chip")).toHaveCount(2);
  await expect(page.locator("#bp-pass-chips .chip").nth(1)).toContainText("cactus");
  await expect(page.locator("#bp-pass-input")).toBeFocused();
});

// Create UX: the result replaces the form, burn shows a clear destroyed state and hides the now-useless
// link, and "Create another" resets to a fresh form with a newly generated phrase.
test("create UX: result replaces form, burn destroys, reset regenerates a fresh phrase", async ({ page }) => {
  await page.goto("/");
  await page.fill("#bp-input", "burn-me " + rnd());
  await page.getByRole("button", { name: "Encrypt & create link" }).click();

  await expect(page.locator("#bp-result")).toBeVisible();
  await expect(page.locator("#bp-create")).toBeHidden(); // the form is replaced, not stacked under

  await page.getByRole("button", { name: "Burn it now" }).click();
  await expect(page.locator("#bp-burned")).toBeVisible();
  await expect(page.locator("#bp-share")).toBeHidden();

  await page.getByRole("button", { name: /create another/i }).click();
  await expect(page.locator("#bp-create")).toBeVisible();
  await expect(page.locator("#bp-result")).toBeHidden();
  await expect(page.locator("#bp-input")).toHaveValue("");
  await expect(page.locator("#bp-pass-chips .chip")).toHaveCount(7); // a fresh phrase is regenerated
});

// Purist reveal: a #fragment means a link-mode (0x01) link this client doesn't mint or open — it's
// refused with a clear message instead of guessing.
test("a #fragment (link-mode) reveal URL is refused", async ({ page, context }) => {
  await page.goto("/");
  await page.fill("#bp-input", "frag " + rnd());
  await page.getByRole("button", { name: "Encrypt & create link" }).click();
  await expect(page.locator("#bp-result")).toBeVisible();
  const link = await page.locator("#bp-link").getAttribute("data-full-url"); // full URL (display drops the scheme)

  // the secret stays live (we don't reveal it); appending a fragment mimics a link-mode link
  const r = await context.newPage();
  await r.goto(link + "#abc123");
  await expect(r.locator("#bp-unsupported")).toBeVisible();
  await expect(r.locator("#bp-psk")).toBeHidden();
});

// The whole create flow (WebCrypto + fetch + the hand-rolled autocomplete) must run under the strict CSP
// with SRI-pinned scripts and no inline scripts. Any CSP/SRI/CORS failure surfaces as a console/page error.
test("strict CSP + SRI hold in a real browser (no console errors during create)", async ({ page }) => {
  const errors = [];
  page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
  page.on("pageerror", (e) => errors.push(String(e)));

  await page.goto("/");
  const csp = (await page.request.get("/")).headers()["content-security-policy"];
  expect(csp).toContain("script-src 'self'");

  await page.fill("#bp-input", "csp check " + rnd());
  await page.getByRole("button", { name: "Encrypt & create link" }).click();
  await expect(page.locator("#bp-link")).toBeVisible();

  expect(errors, "no CSP/SRI/JS console errors").toEqual([]);
});
