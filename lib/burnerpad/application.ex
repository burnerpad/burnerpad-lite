# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Burnerpad.Config.load!()

    # Refuse to boot if any served crypto asset differs from its committed SRI hash (M1) — a tampered or
    # drifted build fails closed instead of silently serving different bytes than were reviewed.
    BurnerpadWeb.CryptoAssets.verify!()

    children = [
      # Owns aggregate UTC-day homepage + successful-create counts only. No visitor/secret identifiers.
      Burnerpad.DailyStats,
      # Owns the in-memory secrets table + the TTL sweep.
      Burnerpad.Store,
      # Owns the rate-limit / global-ceiling / ban / stats tables + their sweep.
      Burnerpad.Abuse,
      # The HTTP server. Plain HTTP — terminate TLS at a reverse proxy.
      # HTTP/1.1 only, no WebSocket: the app has no use for either, and disabling them removes the entire
      # HTTP/2 + HPACK attack surface (the class of CVEs fixed by the bandit/hpax bump) regardless of version.
      {
        Bandit,
        # Bound slow/malformed connection state before a request reaches Plug. The defaults permit over a
        # million concurrent connections and 60s idle reads, which is inappropriate for this small service.
        # Ciphertext is incompressible. Disabling origin compression removes CPU and compression-oracle
        # surface; the edge may still compress public static text.
        plug: BurnerpadWeb.Router,
        scheme: :http,
        port: Burnerpad.Config.get(:port),
        thousand_island_options: [
          num_acceptors: 10,
          num_connections: 100,
          max_connections_retry_count: 0,
          read_timeout: 10_000,
          shutdown_timeout: 10_000
        ],
        http_options: [
          compress: false,
          log_exceptions_with_status_codes: [],
          log_protocol_errors: false,
          log_client_closures: false
        ],
        http_1_options: [
          max_request_line_length: 2_048,
          max_header_length: 8_192,
          max_header_count: 30,
          max_requests: 1_000
        ],
        http_2_options: [enabled: false],
        websocket_options: [enabled: false]
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Burnerpad.Supervisor)
  end
end
