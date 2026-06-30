# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.Router do
  @moduledoc """
  The entire HTTP surface: the create page, the non-burning reveal interstitial, the burn-on-read
  reveal, manual revoke, abuse report, and the create API.

  Sessionless and CSRF-free by design — authorization is *possession* of an unguessable capability
  (the id + the key/passphrase, or the management token), not a cookie.
  """
  use Plug.Router
  use Plug.ErrorHandler
  require Logger
  alias Burnerpad.{Abuse, Config, Store}
  alias BurnerpadWeb.{Pages, SecurityHeaders}

  plug(Plug.RequestId)
  plug(Plug.Logger)
  # Set security headers first so even short-circuited (429/503) and static responses carry them.
  plug(BurnerpadWeb.SecurityHeaders)
  # Count + ban BEFORE static, so every request (incl. assets) counts toward the limit.
  plug(BurnerpadWeb.AbusePlug)

  # App-owned page assets (this repo, AGPL). Served at STABLE paths (no content hash in the filename) and
  # pinned by SRI in the HTML, so they must revalidate: `no-cache` lets the browser keep a copy but check
  # the ETag every load (cheap 304s). An `immutable`/long max-age here would serve a stale script that the
  # page's fresh SRI then blocks — silently breaking the UI after any update. (Fingerprinted: immutable.)
  plug(Plug.Static,
    at: "/crypto",
    from: {:burnerpad, "priv/static/crypto"},
    only: ~w(crypto-app.js crypto.css theme.js),
    cache_control_for_etags: "no-cache"
  )

  # Self-hosted web fonts (SIL OFL 1.1 — see priv/static/fonts/NOTICE.md). Served same-origin so the
  # strict CSP keeps `font-src 'self'`. Cached fresh for up to a week, then revalidated (no `immutable`):
  # a face swapped under the same filename is picked up within ~7 days — fine for cosmetic, non-SRI-pinned
  # assets (unlike the scripts, a stale font can't trip an SRI mismatch; no key material touches a font).
  plug(Plug.Static,
    at: "/fonts",
    from: {:burnerpad, "priv/static/fonts"},
    only: ~w(hanken-grotesk-latin.woff2 baloo2-latin.woff2 jetbrains-mono-latin.woff2),
    cache_control_for_etags: "public, max-age=604800"
  )

  # The crypto library (@burnerpad/crypto, Apache-2.0), vendored as a pinned git submodule under
  # priv/static/vendor/crypto-js. Served at the same /crypto path and SRI-pinned exactly like the rest;
  # the bytes are never copied into this repo. Run `mix setup` after cloning to fetch the submodule.
  plug(Plug.Static,
    at: "/crypto",
    from: {:burnerpad, "priv/static/vendor/crypto-js"},
    only: ~w(burnerpad-crypto.js),
    cache_control_for_etags: "no-cache"
  )

  # RFC 9116 security contact, served at /.well-known/security.txt (see SECURITY.md).
  plug(Plug.Static,
    at: "/.well-known",
    from: {:burnerpad, "priv/static/.well-known"},
    only: ~w(security.txt)
  )

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: JSON,
    # Cap the body BEFORE buffering: the only body we accept is a ~64 KB ciphertext blob
    # (base64url ~88 KB + small JSON overhead). Reject anything larger up front.
    length: 100_000
  )

  plug(:match)
  plug(:dispatch)

  ## ── routes ──────────────────────────────────────────────────────────────

  get "/" do
    html(conn, 200, Pages.home())
  end

  get "/s/:id" do
    case Store.peek(id) do
      {:ok, :live} ->
        {:ok, nid} = Store.normalize(id)
        html(conn, 200, Pages.view(nid))

      :gone ->
        html(
          conn,
          404,
          Pages.status(
            "This link leads nowhere",
            "The page doesn't exist — or the secret that lived here has already been opened and burned."
          )
        )
    end
  end

  # Atomic burn + return ciphertext exactly once.
  post "/s/:id/reveal" do
    case Store.reveal(id) do
      {:ok, blob} -> json(conn, 200, %{blob: Base.url_encode64(blob, padding: false)})
      :gone -> json(conn, 410, %{status: "gone"})
    end
  end

  # Manual revoke with the management token.
  post "/s/:id/burn" do
    case Store.burn(id, conn.body_params["mgmt_token"]) do
      :ok -> json(conn, 200, %{status: "burned"})
      :error -> json(conn, 403, %{error: "invalid token"})
    end
  end

  # Non-destructive abuse flag (always 200, even for unknown ids — no existence oracle).
  post "/s/:id/report" do
    # Log only the id (so an operator can purge-by-id on a valid notice) — never the reporter's IP
    # alongside it, which would persist an IP↔secret-id link the design deliberately avoids.
    Logger.warning("report: secret #{inspect(id)} reported")
    json(conn, 200, %{status: "reported"})
  end

  # Store an opaque ciphertext blob.
  post "/api/secrets" do
    max_blob = Config.get(:max_blob)

    with b64 when is_binary(b64) <- conn.body_params["blob"],
         {:ok, blob} <- Base.url_decode64(b64, padding: false),
         size when size > 0 and size <= max_blob <- byte_size(blob),
         {:ok, id, mgmt} <- create(blob, conn.body_params["ttl"]) do
      json(conn, 200, %{id: id, mgmt_token: mgmt})
    else
      {:error, :full} -> json(conn, 503, %{error: "service full, try again later"})
      _ -> json(conn, 400, %{error: "invalid blob"})
    end
  end

  # Programmatic take: GET burns + returns the blob exactly once. Convenient for CLI/scripts; the
  # browser flow deliberately uses the non-burning GET /s/:id + POST /s/:id/reveal instead, so that
  # link-preview bots prefetching a shared URL cannot destroy the secret.
  get "/api/secrets/:id" do
    case Store.reveal(id) do
      {:ok, blob} -> json(conn, 200, %{blob: Base.url_encode64(blob, padding: false)})
      :gone -> json(conn, 410, %{status: "gone"})
    end
  end

  # Public, aggregate transparency page — counts only, nothing about any secret or user.
  get "/stats" do
    html(conn, 200, Pages.stats(stats_map()))
  end

  get "/stats.json" do
    json(conn, 200, stats_map())
  end

  # Public Terms & Acceptable-Use (a template rendered with operator placeholders from config).
  get "/terms" do
    html(conn, 200, Pages.terms())
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  ## ── helpers ─────────────────────────────────────────────────────────────

  defp create(blob, ttl) when is_integer(ttl), do: Store.create(blob, ttl)
  defp create(blob, _), do: Store.create(blob)

  defp stats_map, do: Map.merge(Store.metrics(), Abuse.metrics())

  # Every dynamic response is non-cacheable via the one shared policy (SecurityHeaders.no_store/1).
  defp html(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> SecurityHeaders.no_store()
    |> send_resp(status, body)
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> SecurityHeaders.no_store()
    |> send_resp(status, JSON.encode!(data))
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: reason}) do
    status = if is_exception(reason), do: Plug.Exception.status(reason), else: conn.status || 500
    # Generic message only — never leak internals/stack traces to the client.
    if status >= 500, do: Logger.error("unhandled error: #{inspect(reason)}")

    conn
    |> put_resp_content_type("application/json")
    |> SecurityHeaders.no_store()
    |> send_resp(status, JSON.encode!(%{error: "request failed"}))
  end
end
