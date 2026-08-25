// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import { readFileSync } from "node:fs";

const fail = () => {
  // The response is aggregate/public today, but keep failures generic so this helper remains safe if the
  // endpoint grows fields later. Ansible needs only the exit status; never echo malformed input.
  process.stderr.write("Unable to verify the resident ciphertext count.\n");
  process.exitCode = 1;
};

try {
  const input = readFileSync(0, "utf8");

  if (Buffer.byteLength(input, "utf8") > 64 * 1024) {
    fail();
  } else {
    const stats = JSON.parse(input);
    const isObject = stats !== null && typeof stats === "object" && !Array.isArray(stats);
    const hasOwn = (key) => Object.prototype.hasOwnProperty.call(stats, key);

    // `stored` was the exact ETS row count exposed by pre-1.0 releases. Current releases expose the same
    // count as the precise `resident` term and retain `stored` only as an API compatibility alias.
    const count = isObject && hasOwn("resident") ? stats.resident : isObject && hasOwn("stored") ? stats.stored : null;

    if (!Number.isSafeInteger(count) || count < 0) {
      fail();
    } else {
      process.stdout.write(`${count}\n`);
    }
  }
} catch {
  fail();
}
