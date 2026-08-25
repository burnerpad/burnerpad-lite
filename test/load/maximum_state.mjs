// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import { writeFile } from "node:fs/promises";

const reportPath = process.argv[2];
if (!reportPath) throw new Error("usage: node maximum_state.mjs REPORT_PATH");

const integerEnv = (name, fallback) => {
  const value = Number(process.env[name] || fallback);
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`invalid ${name}`);
  return value;
};

const baseUrl = process.env.LOAD_BASE_URL || "http://app:4000";
const maxSecrets = integerEnv("LOAD_MAX_SECRETS", 50_000);
const maxBlobBytes = integerEnv("LOAD_MAX_BLOB_BYTES", 65_536);
const concurrency = integerEnv("LOAD_CONCURRENCY", 64);
const cycleSecrets = Math.min(integerEnv("LOAD_CYCLE_SECRETS", 2_000), maxSecrets);
const rejectionRequests = integerEnv("LOAD_REJECTION_REQUESTS", 256);
const probeRequests = integerEnv("LOAD_PROBE_REQUESTS", 256);
const requestTimeoutMs = integerEnv("LOAD_REQUEST_TIMEOUT_MS", 30_000);
const mutationP99LimitMs = integerEnv("LOAD_MUTATION_P99_LIMIT_MS", 2_000);
const probeP99LimitMs = integerEnv("LOAD_PROBE_P99_LIMIT_MS", 1_000);
const hostMemoryGiB = integerEnv("LOAD_HOST_MEMORY_GIB", 8);
const appMemoryGiB = integerEnv("LOAD_APP_MEMORY_GIB", 6);
const appCpus = integerEnv("LOAD_CPUS", 4);
const monitorIntervalMs = integerEnv("LOAD_MONITOR_INTERVAL_MS", 100);

if (maxSecrets + cycleSecrets + rejectionRequests * 2 + probeRequests > 131_072) {
  throw new Error("the load profile needs more unique benchmark source addresses than 198.18.0.0/15 provides");
}

const blob = Buffer.alloc(maxBlobBytes, 0xa5).toString("base64url");
const createBody = JSON.stringify({ blob, ttl: 86_400 });
const secrets = new Array(maxSecrets);
let sourceSequence = 0;
const monitoring = {
  interval_ms: monitorIntervalMs,
  samples: 0,
  errors: [],
  peak: {
    resident: 0,
    admission_queue: 0,
    create_queue: 0,
    admission_busy_total: 0,
    create_busy_total: 0,
    internal_errors_total: 0
  }
};
let monitorInFlight = false;

const sourceAddress = (sequence) => {
  const second = 18 + Math.floor(sequence / 65_536);
  const remainder = sequence % 65_536;
  return `198.${second}.${Math.floor(remainder / 256)}.${remainder % 256}`;
};

const nextSource = () => sourceAddress(sourceSequence++);

async function request(path, options = {}) {
  const response = await fetch(baseUrl + path, {
    ...options,
    signal: AbortSignal.timeout(requestTimeoutMs)
  });
  const text = await response.text();
  let body = null;
  if (text) {
    try { body = JSON.parse(text); }
    catch { body = text; }
  }
  return { status: response.status, body };
}

const percentile = (sorted, fraction) => {
  const index = Math.max(0, Math.ceil(sorted.length * fraction) - 1);
  return Number(sorted[index].toFixed(2));
};

async function runPhase(name, total, expectedStatus, p99LimitMs, operation) {
  const started = performance.now();
  const latencies = new Array(total);
  const statusCounts = new Map();
  const failures = [];
  let nextIndex = 0;
  let completed = 0;
  let nextProgress = Math.min(5_000, total);

  const worker = async () => {
    while (true) {
      const index = nextIndex++;
      if (index >= total) return;
      const requestStarted = performance.now();
      try {
        const result = await operation(index);
        latencies[index] = performance.now() - requestStarted;
        statusCounts.set(result.status, (statusCounts.get(result.status) || 0) + 1);
        if (result.status !== expectedStatus && failures.length < 20) {
          failures.push({ index, status: result.status, body: String(result.body).slice(0, 200) });
        }
      } catch (error) {
        latencies[index] = performance.now() - requestStarted;
        if (failures.length < 20) failures.push({ index, error: String(error) });
      }

      completed++;
      if (completed >= nextProgress) {
        const seconds = (performance.now() - started) / 1_000;
        process.stderr.write(`${name}: ${completed}/${total} (${(completed / seconds).toFixed(1)} req/s)\n`);
        nextProgress += 5_000;
      }
    }
  };

  await Promise.all(Array.from({ length: Math.min(concurrency, total) }, worker));
  if (failures.length) throw new Error(`${name} failures: ${JSON.stringify(failures)}`);

  const elapsedMs = performance.now() - started;
  const sorted = [...latencies].sort((a, b) => a - b);
  const summary = {
    requests: total,
    expected_status: expectedStatus,
    statuses: Object.fromEntries([...statusCounts].sort(([a], [b]) => a - b)),
    elapsed_ms: Number(elapsedMs.toFixed(2)),
    throughput_rps: Number((total / (elapsedMs / 1_000)).toFixed(2)),
    latency_ms: {
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      p99: percentile(sorted, 0.99),
      max: Number(sorted.at(-1).toFixed(2))
    }
  };

  if (summary.latency_ms.p99 > p99LimitMs) {
    throw new Error(`${name} p99 ${summary.latency_ms.p99}ms exceeded ${p99LimitMs}ms`);
  }
  return summary;
}

const create = async (index, captureSecret, source = nextSource()) => {
  const result = await request("/api/secrets", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      "cf-connecting-ip": source
    },
    body: createBody
  });
  if (captureSecret && result.status === 200) {
    if (!result.body || typeof result.body.id !== "string" || typeof result.body.mgmt_token !== "string") {
      throw new Error("create response omitted id or management token");
    }
    secrets[index] = { id: result.body.id, managementToken: result.body.mgmt_token, source };
  }
  return result;
};

const stats = async (source = "192.0.2.1") => {
  const result = await request("/api/stats", {
    headers: { accept: "application/json", "cf-connecting-ip": source }
  });
  if (result.status !== 200 || !result.body || typeof result.body.resident !== "number") {
    throw new Error(`stats unavailable: ${JSON.stringify(result)}`);
  }
  return result.body;
};

const assertResident = async (expected) => {
  const current = await stats();
  if (current.resident !== expected || current.capacity !== maxSecrets) {
    throw new Error(`resident/capacity mismatch: expected ${expected}/${maxSecrets}, got ${current.resident}/${current.capacity}`);
  }
  return current;
};

const sampleRuntime = async () => {
  if (monitorInFlight) return;
  monitorInFlight = true;
  try {
    const current = await stats();
    monitoring.samples++;
    for (const name of Object.keys(monitoring.peak)) {
      monitoring.peak[name] = Math.max(monitoring.peak[name], current[name] || 0);
    }
  } catch (error) {
    if (monitoring.errors.length < 20) monitoring.errors.push(String(error));
  } finally {
    monitorInFlight = false;
  }
};

await sampleRuntime();
const monitorTimer = setInterval(sampleRuntime, monitorIntervalMs);
monitorTimer.unref();

const startedAt = new Date().toISOString();
const overallStarted = performance.now();
const phases = {};

phases.fill = await runPhase("fill", maxSecrets, 200, mutationP99LimitMs, (index) => create(index, true));
await assertResident(maxSecrets);

phases.reject_at_capacity = await runPhase(
  "reject_at_capacity",
  rejectionRequests,
  503,
  mutationP99LimitMs,
  (index) => create(index, false, secrets[index % maxSecrets].source)
);

phases.readiness_at_capacity = await runPhase(
  "readiness_at_capacity",
  probeRequests,
  200,
  probeP99LimitMs,
  async (index) => index % 2 === 0
    ? request("/readyz")
    : request("/api/stats", {
      headers: { accept: "application/json", "cf-connecting-ip": secrets[index % maxSecrets].source }
    })
);

phases.reveal_and_burn = await runPhase("reveal_and_burn", cycleSecrets, 200, mutationP99LimitMs, async (index) => {
  const secret = secrets[index];
  const reveal = index % 2 === 0;
  const result = await request(`/api/secrets/${secret.id}/${reveal ? "reveal" : "burn"}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      "cf-connecting-ip": secret.source
    },
    body: reveal ? "{}" : JSON.stringify({ mgmt_token: secret.managementToken })
  });
  if (reveal && result.status === 200) {
    const decoded = Buffer.from(result.body?.blob || "", "base64url");
    if (decoded.length !== maxBlobBytes) throw new Error(`reveal returned ${decoded.length} bytes`);
  }
  return result;
});
await assertResident(maxSecrets - cycleSecrets);

phases.refill = await runPhase(
  "refill",
  cycleSecrets,
  200,
  mutationP99LimitMs,
  (index) => create(index, false, secrets[index].source)
);
await assertResident(maxSecrets);

phases.reject_after_refill = await runPhase(
  "reject_after_refill",
  rejectionRequests,
  503,
  mutationP99LimitMs,
  (index) => create(index, false, secrets[index % maxSecrets].source)
);

await new Promise((resolve) => setTimeout(resolve, 1_000));
phases.recovery_after_load = await runPhase(
  "recovery_after_load",
  probeRequests,
  200,
  probeP99LimitMs,
  async (index) => index % 2 === 0
    ? request("/readyz")
    : request("/api/stats", {
      headers: { accept: "application/json", "cf-connecting-ip": secrets[index % maxSecrets].source }
    })
);

clearInterval(monitorTimer);
while (monitorInFlight) await new Promise((resolve) => setTimeout(resolve, 10));
if (monitoring.errors.length) throw new Error(`runtime monitoring failed: ${JSON.stringify(monitoring.errors)}`);

const recoveredStats = await stats();
if (recoveredStats.admission_queue !== 0 || recoveredStats.create_queue !== 0) {
  throw new Error(`queues did not recover after load: ${JSON.stringify(recoveredStats)}`);
}

const report = {
  started_at: startedAt,
  finished_at: new Date().toISOString(),
  elapsed_ms: Number((performance.now() - overallStarted).toFixed(2)),
  profile: {
    host_memory_gib: hostMemoryGiB,
    app_memory_limit_gib: appMemoryGiB,
    app_cpus: appCpus,
    max_secrets: maxSecrets,
    max_blob_bytes: maxBlobBytes,
    raw_ciphertext_gib: Number((maxSecrets * maxBlobBytes / 1024 ** 3).toFixed(3)),
    concurrency,
    cycle_secrets: cycleSecrets,
    request_timeout_ms: requestTimeoutMs,
    mutation_p99_limit_ms: mutationP99LimitMs,
    probe_p99_limit_ms: probeP99LimitMs
  },
  phases,
  monitoring,
  final_stats: recoveredStats
};

await writeFile(reportPath, JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
process.stdout.write(JSON.stringify(report, null, 2) + "\n");
