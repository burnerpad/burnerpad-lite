// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

const loopbackHosts = new Set(["127.0.0.1", "localhost", "[::1]"]);

/**
 * Accept exactly one canonical origin. Public canaries require HTTPS; local tests may use HTTP only on
 * loopback. Exact comparison rejects credentials, paths, query strings, fragments, trailing slashes, and
 * URL spellings that the URL parser would silently normalize before the first request.
 */
export const parseCanaryOrigin = (raw, { requireHttps = false } = {}) => {
  let parsed;
  const requirement = requireHttps
    ? "one canonical HTTPS origin"
    : "one canonical HTTPS or loopback HTTP origin";

  try {
    parsed = new URL(raw);
  } catch {
    throw new Error(`BURNERPAD_BASE_URL must be ${requirement}`);
  }

  const secure = parsed.protocol === "https:";
  const localHttp = parsed.protocol === "http:" && loopbackHosts.has(parsed.hostname);
  if (
    parsed.origin !== raw ||
    parsed.pathname !== "/" ||
    parsed.username !== "" ||
    parsed.password !== "" ||
    parsed.search !== "" ||
    parsed.hash !== "" ||
    (requireHttps ? !secure : !secure && !localHttp)
  ) {
    throw new Error(`BURNERPAD_BASE_URL must be ${requirement}`);
  }

  return parsed;
};
