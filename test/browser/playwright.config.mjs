// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import { defineConfig, devices } from "@playwright/test";

const PORT = Number(process.env.BROWSER_TEST_PORT || "4014");
const BASE = process.env.BROWSER_TEST_BASE_URL || `http://127.0.0.1:${PORT}`;
const EXTERNAL_SERVER = process.env.BROWSER_TEST_EXTERNAL_SERVER === "1";

// Boots the real Elixir server (from the project root, two levels up) for the test run, then tears it
// down. Generous limits so the test traffic isn't rate-limited.
export default defineConfig({
  testDir: ".",
  outputDir: process.env.PLAYWRIGHT_OUTPUT_DIR || "test-results",
  timeout: 30_000,
  fullyParallel: false,
  // Keep local feedback parallel, but avoid starving browser processes on shared CI runners. A retry
  // gets a fresh Playwright worker/browser, while deterministic failures still fail all attempts.
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: [["list"]],
  use: {
    baseURL: BASE,
    headless: true
  },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"], channel: undefined } },
    { name: "firefox", use: { ...devices["Desktop Firefox"] } },
    { name: "webkit", use: { ...devices["Desktop Safari"] } },
    { name: "mobile-webkit", use: { ...devices["iPhone 13"] } },
  ],
  webServer: EXTERNAL_SERVER
    ? undefined
    : {
        command: "mix run --no-halt",
        cwd: "../..",
        url: BASE,
        timeout: 60_000,
        reuseExistingServer: true,
        env: {
          PORT: String(PORT),
          RATE_LIMIT: "100000",
          BAN_THRESHOLD: "500000",
          GLOBAL_CEILING: "1000000",
          MAX_SECRETS: "100000"
        }
      }
});
