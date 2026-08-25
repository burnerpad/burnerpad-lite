// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import assert from "node:assert/strict";
import test from "node:test";
import { verifySourceIdentity } from "../../ops/smoke/edge-source-contract.mjs";

const response = ({ status = 200, body = "", cacheControl = "" } = {}) => ({
  ok: status >= 200 && status < 300,
  status,
  text: async () => body,
  headers: { get: (name) => name.toLowerCase() === "cache-control" ? cacheControl : null },
});

test("source contract compares the edge observation and resists a forged forwarding header", async () => {
  const calls = [];
  const request = async (url, init = {}) => {
    calls.push({ url, init });
    if (url.endsWith("/cdn-cgi/trace")) return response({ body: "fl=1\nip=203.0.113.7\ncolo=BCN\n" });
    return response({ status: 204, cacheControl: "no-store" });
  };

  await verifySourceIdentity(request, "https://burnerpad.example");

  assert.equal(calls.length, 3);
  assert.equal(calls[1].url, "https://burnerpad.example/api/edge/source-check");
  assert.deepEqual(JSON.parse(calls[1].init.body), { expected_ip: "203.0.113.7" });
  assert.equal(calls[1].init.headers["cf-connecting-ip"], undefined);
  assert.equal(calls[2].init.headers["cf-connecting-ip"], "192.0.2.1");
  assert.deepEqual(JSON.parse(calls[2].init.body), { expected_ip: "203.0.113.7" });
});

test("source contract accepts an IPv6 edge observation without normalizing it client-side", async () => {
  const bodies = [];
  const request = async (url, init = {}) => {
    if (url.endsWith("/cdn-cgi/trace")) return response({ body: "ip=2001:db8:1:2:3:4:5:6\n" });
    bodies.push(JSON.parse(init.body));
    return response({ status: 204, cacheControl: "no-store" });
  };

  await verifySourceIdentity(request, "https://burnerpad.example");
  assert.deepEqual(bodies, [
    { expected_ip: "2001:db8:1:2:3:4:5:6" },
    { expected_ip: "2001:db8:1:2:3:4:5:6" },
  ]);
});

test("source contract rejects a malformed or ambiguous Cloudflare trace without echoing it", async () => {
  for (const body of ["colo=BCN\n", "ip=203.0.113.7\nip=203.0.113.8\n", "ip=not-an-ip\n"]) {
    const request = async () => response({ body });

    await assert.rejects(
      verifySourceIdentity(request, "https://burnerpad.example"),
      (error) => error.stage === "client_ip_trace" && !error.message.includes(body.trim()),
    );
  }
});

test("source contract identifies baseline and spoof failures without including the address", async () => {
  for (const { failingCall, stage } of [
    { failingCall: 2, stage: "client_ip_baseline" },
    { failingCall: 3, stage: "client_ip_spoof" },
  ]) {
    let calls = 0;
    const request = async (url) => {
      calls++;
      if (url.endsWith("/cdn-cgi/trace")) return response({ body: "ip=203.0.113.7\n" });
      return response({ status: calls === failingCall ? 409 : 204, cacheControl: "no-store" });
    };

    await assert.rejects(
      verifySourceIdentity(request, "https://burnerpad.example"),
      (error) => error.stage === stage && !error.message.includes("203.0.113.7"),
    );
  }
});
