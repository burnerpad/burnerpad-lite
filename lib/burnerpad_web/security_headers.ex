# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.SecurityHeaders do
  @moduledoc """
  Strict response headers for every response. The crypto pages carry **no inline scripts**, so
  `script-src 'self'` is enforceable; `Referrer-Policy: no-referrer` keeps the URL `#fragment`
  (the decryption key) out of the `Referer` header.
  """
  import Plug.Conn

  @csp [
         "default-src 'none'",
         "script-src 'self'",
         "style-src 'self'",
         # Fonts are self-hosted (served from /fonts, same-origin) — no external font CDN, so a
         # narrow `font-src 'self'` keeps the policy strict while allowing the bundled WOFF2 faces.
         "font-src 'self'",
         "connect-src 'self'",
         "img-src 'self'",
         "base-uri 'none'",
         "form-action 'none'",
         "frame-ancestors 'none'"
       ]
       |> Enum.join("; ")

  @permissions [
                 "accelerometer=()",
                 "autoplay=()",
                 "camera=()",
                 "geolocation=()",
                 "gyroscope=()",
                 "magnetometer=()",
                 "microphone=()",
                 "payment=()",
                 "usb=()",
                 "interest-cohort=()"
               ]
               |> Enum.join(", ")

  @headers [
    {"content-security-policy", @csp},
    {"referrer-policy", "no-referrer"},
    {"x-content-type-options", "nosniff"},
    {"x-permitted-cross-domain-policies", "none"},
    {"strict-transport-security", "max-age=63072000; includeSubDomains; preload"},
    {"cross-origin-resource-policy", "same-origin"},
    {"cross-origin-opener-policy", "same-origin"},
    {"permissions-policy", @permissions}
  ]

  def init(opts), do: opts

  def call(conn, _opts), do: merge_resp_headers(conn, @headers)

  @doc """
  Mark a response non-cacheable — the single definition of this app's "never cache this" policy.

  Every DYNAMIC send site routes through it: the router's `html`/`json` helpers, the error handler, AND the
  abuse short-circuit (429/503). That keeps the one-time reveal ciphertext and the single-use `mgmt_token`
  out of every browser/proxy cache from ONE place — change the policy here and it changes everywhere. Static
  assets never call it, so `Plug.Static` keeps its own ETag-revalidation / max-age caching (the SRI-pinned
  scripts must stay cacheable-but-revalidated, so a returning browser gets a cheap 304, not a full refetch).
  """
  def no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
