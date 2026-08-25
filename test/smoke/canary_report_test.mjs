// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { createCanaryReporter } from "../../ops/smoke/canary-report.mjs";

const revisionA = "a".repeat(40);
const revisionB = "b".repeat(40);
const repoDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

const capture = () => {
  const logs = [];
  const outputs = [];
  const reporter = createCanaryReporter({
    check: "end_to_end",
    logger: {
      log: (message) => logs.push(message),
      error: (message) => logs.push(message),
    },
    writeOutput: (fields) => outputs.push(fields),
  });
  return { reporter, logs, outputs };
};

test("reporter emits only a fixed stage and validated observed revision", () => {
  const { reporter, logs, outputs } = capture();
  reporter.setStage("release_identity");
  reporter.configureExpectedRevision(revisionA, { required: true });
  assert.equal(reporter.observeStats({ version: `1.0.0+${revisionA}` }), revisionA);
  reporter.setStage("reveal");
  reporter.failed();

  assert.deepEqual(outputs, [{
    status: "failure",
    check: "end_to_end",
    stage: "reveal",
    release: revisionA,
    release_source: "observed",
    expected_release: revisionA,
  }]);
  assert.equal(
    logs[0],
    `Burnerpad end_to_end canary failed stage=reveal release=${revisionA} release_source=observed`,
  );
});

test("reporter rejects untrusted stage and revision strings before output", () => {
  const { reporter } = capture();
  assert.throws(() => reporter.setStage("reveal id=secret"), /invalid canary stage/);
  assert.throws(() => reporter.configureExpectedRevision(`${revisionA}\ncapability=value`), /invalid/);
  assert.throws(() => reporter.observeStats({ version: "1.0.0+not-a-release" }), /invalid/);
  assert.throws(() => reporter.observeStats({ version: `1.0.0+${revisionA}\nsecret` }), /invalid/);
});

test("reporter uses an expected revision when the public identity is unavailable", () => {
  const { reporter, outputs } = capture();
  reporter.setStage("configuration");
  reporter.configureExpectedRevision(revisionA, { required: true });
  reporter.setStage("release_identity");
  reporter.failed();

  assert.equal(outputs[0].release, revisionA);
  assert.equal(outputs[0].release_source, "expected");
});

test("reporter fails closed on a missing required or mismatched expected revision", () => {
  const missing = capture().reporter;
  assert.throws(() => missing.configureExpectedRevision("", { required: true }), /required/);

  const mismatch = capture().reporter;
  mismatch.configureExpectedRevision(revisionA, { required: true });
  assert.throws(
    () => mismatch.observeStats({ version: `1.0.0+${revisionB}` }),
    /does not match/,
  );
});

const runCanary = async (handler, { expectedRevision = revisionA, timeoutMs = 5_000 } = {}) => {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "burnerpad-canary-report-"));
  const outputFile = path.join(tempDir, "github-output");

  try {
    const child = spawn(process.execPath, ["ops/smoke/e2e-canary.mjs"], {
      cwd: repoDir,
      env: {
        ...process.env,
        BURNERPAD_BASE_URL: `http://127.0.0.1:${address.port}`,
        BURNERPAD_EXPECTED_REVISION: expectedRevision,
        BURNERPAD_REQUIRE_EXPECTED_REVISION: "true",
        BURNERPAD_CANARY_TIMEOUT_MS: String(timeoutMs),
        GITHUB_OUTPUT: outputFile,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const exitCode = await new Promise((resolve) => child.on("close", resolve));
    return { exitCode, stdout, stderr, output: await readFile(outputFile, "utf8") };
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(tempDir, { recursive: true, force: true });
  }
};

test("end-to-end transport failure reports its stage and the observed release only", async () => {
  const result = await runCanary((request, response) => {
    if (request.url === "/api/stats") {
      response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
      response.end(JSON.stringify({ version: `1.0.0+${revisionA}` }));
    } else if (request.url === "/readyz") {
      response.writeHead(200, { "cache-control": "no-store" });
      response.end("ready");
    } else {
      request.socket.destroy();
    }
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.stdout, "");
  assert.equal(
    result.stderr,
    `Burnerpad end_to_end canary failed stage=create release=${revisionA} release_source=observed\n`,
  );
  assert.match(result.output, /^status=failure\ncheck=end_to_end\nstage=create\n/);
  assert.doesNotMatch(result.stderr + result.output, /\/api\/secrets|phrase|blob|plaintext|capability/);
});

test("a ready target completes the encrypted transaction through the canary process", async () => {
  let heldBlob = "";
  let claimed = false;

  const result = await runCanary(async (request, response) => {
    const headers = { "content-type": "application/json", "cache-control": "no-store" };

    if (request.url === "/readyz") {
      response.writeHead(200, { "content-type": "text/plain", "cache-control": "no-store" });
      response.end("ready");
    } else if (request.url === "/api/stats") {
      response.writeHead(200, headers);
      response.end(JSON.stringify({ version: `1.0.0+${revisionA}` }));
    } else if (request.method === "POST" && request.url === "/api/secrets") {
      let body = "";
      for await (const chunk of request) body += chunk;
      heldBlob = JSON.parse(body).blob;
      response.writeHead(200, headers);
      response.end(JSON.stringify({ id: "CANARY", mgmt_token: "unused", ttl: 60 }));
    } else if (request.method === "POST" && request.url === "/api/secrets/CANARY/reveal") {
      if (claimed) {
        response.writeHead(404, headers);
        response.end(JSON.stringify({ error: "not found" }));
      } else {
        claimed = true;
        response.writeHead(200, headers);
        response.end(JSON.stringify({ blob: heldBlob }));
      }
    } else {
      response.writeHead(404, headers);
      response.end(JSON.stringify({ error: "not found" }));
    }
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.stderr, "");
  assert.match(result.stdout, new RegExp(`canary passed release=${revisionA}`));
});

test("readiness outage reports the configured release without response details", async () => {
  const result = await runCanary(
    (_request, response) => {
      response.writeHead(503, { "content-type": "text/plain", "cache-control": "no-store" });
      response.end("sensitive upstream diagnostic");
    },
    { timeoutMs: 250 },
  );

  assert.equal(result.exitCode, 1);
  assert.equal(
    result.stderr,
    `Burnerpad end_to_end canary failed stage=readiness release=${revisionA} release_source=expected\n`,
  );
  assert.doesNotMatch(result.stderr + result.output, /sensitive upstream diagnostic/);
});

test("a ready target with a mismatched identity fails at release_identity", async () => {
  const result = await runCanary((request, response) => {
    if (request.url === "/readyz") {
      response.writeHead(200, { "content-type": "text/plain", "cache-control": "no-store" });
      response.end("ready");
    } else {
      response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
      response.end(JSON.stringify({ version: `1.0.0+${revisionB}` }));
    }
  });

  assert.equal(result.exitCode, 1);
  assert.equal(
    result.stderr,
    `Burnerpad end_to_end canary failed stage=release_identity release=${revisionB} release_source=observed\n`,
  );
});
