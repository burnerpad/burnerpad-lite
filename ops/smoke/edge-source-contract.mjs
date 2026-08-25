// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import net from "node:net";

class SourceContractError extends Error {
  constructor(stage, message) {
    super(message);
    this.name = "SourceContractError";
    this.stage = stage;
  }
}

const fail = (stage, message) => { throw new SourceContractError(stage, message); };

const requestAt = async (request, stage, url, init) => {
  try {
    return await request(url, init);
  } catch (_error) {
    fail(stage, "edge source request failed");
  }
};

const traceIP = async (response) => {
  if (!response.ok) fail("client_ip_trace", "Cloudflare trace rejected");

  let body;
  try {
    body = await response.text();
  } catch (_error) {
    fail("client_ip_trace", "Cloudflare trace was unreadable");
  }
  if (body.length > 8_192) fail("client_ip_trace", "Cloudflare trace was oversized");

  const values = body
    .split(/\r?\n/)
    .filter((line) => line.startsWith("ip="))
    .map((line) => line.slice(3));

  if (values.length !== 1 || net.isIP(values[0]) === 0) {
    fail("client_ip_trace", "Cloudflare trace did not contain one valid source address");
  }
  return values[0];
};

const sourceProbe = async (request, origin, expectedIP, stage, extraHeaders = {}) => {
  const response = await requestAt(request, stage, origin + "/api/edge/source-check", {
    method: "POST",
    headers: {
      "accept": "application/json",
      "content-type": "application/json",
      ...extraHeaders,
    },
    body: JSON.stringify({ expected_ip: expectedIP }),
  });

  if (response.status !== 204 || !/no-store/i.test(response.headers.get("cache-control") || "")) {
    fail(stage, "deployed source resolver did not match the edge observation");
  }
};

export async function verifySourceIdentity(request, origin) {
  const trace = await requestAt(request, "client_ip_trace", origin + "/cdn-cgi/trace");
  const expectedIP = await traceIP(trace);

  await sourceProbe(request, origin, expectedIP, "client_ip_baseline");
  await sourceProbe(request, origin, expectedIP, "client_ip_spoof", {
    "cf-connecting-ip": "192.0.2.1",
  });
}
