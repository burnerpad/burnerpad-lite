// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

export const requireDynamicNoStore = (response) => {
  if (!response.ok) throw new Error("dynamic endpoint rejected");
  if (!/(?:^|,)\s*no-store\s*(?:,|$)/i.test(response.headers.get("cache-control") || "")) {
    throw new Error("dynamic endpoint is cacheable");
  }
  if ((response.headers.get("cf-cache-status") || "").toUpperCase() === "HIT") {
    throw new Error("dynamic endpoint was served from edge cache");
  }
};

export const requireStaticRevalidation = (initial, conditional) => {
  const etag = initial.headers.get("etag") || "";
  if (!etag) throw new Error("static response omitted ETag");
  if (conditional.status !== 304) throw new Error("conditional static request was not revalidated");
  if (conditional.headers.get("etag") !== etag) throw new Error("static ETag changed during revalidation");
};
