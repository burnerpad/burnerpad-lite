// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import { defineConfig, devices } from "@playwright/test";

const PORT = 4014;
const BASE = `http://127.0.0.1:${PORT}`;

// Boots the real Elixir server (from the project root, two levels up) for the test run, then tears it
// down. Generous limits so the test traffic isn't rate-limited.
export default defineConfig({
  testDir: ".",
  timeout: 30_000,
  fullyParallel: false,
  reporter: [["list"]],
  use: {
    baseURL: BASE,
    headless: true,
    launchOptions: { args: ["--no-sandbox", "--disable-dev-shm-usage"] }
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"], channel: undefined } }],
  webServer: {
    command: "mix run --no-halt",
    cwd: "../..",
    url: BASE,
    timeout: 60_000,
    reuseExistingServer: true,
    env: {
      PORT: String(PORT),
      RATE_LIMIT: "100000",
      GLOBAL_CEILING: "1000000",
      MAX_SECRETS: "100000"
    }
  }
});
