# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.Router do
  @moduledoc """
  The entire HTTP surface: the create page, the non-burning reveal interstitial, the burn-on-read
  reveal, manual revoke, aggregate transparency, and the create API.

  Sessionless and CSRF-free by design — authorization is *possession* of an unguessable capability
  (the id + the key/passphrase, or the management token), not a cookie.
  """
  use Plug.Router
  use Plug.ErrorHandler
  require Logger
  alias Burnerpad.{Abuse, Config, DailyStats, Encoding, Store}
  alias BurnerpadWeb.{ClientIP, Pages, RouteClass, SecurityHeaders}

  # Security headers FIRST (L6) so even short-circuited (429/503), static, and error responses carry them.
  plug(BurnerpadWeb.SecurityHeaders)
  plug(Plug.RequestId)

  # Liveness/readiness endpoints, served BEFORE the limiter so internal probes never consume capacity.
  plug(:healthz)

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

  # Count + ban only DYNAMIC requests — the static assets above are served (and halted) before this, so a
  # page load's ~8 css/js/font requests no longer burn the per-IP rate limit or the global ceiling (L12).
  plug(BurnerpadWeb.AbusePlug)

  # Sanitized operational event only: allowlisted route class/method/status/duration/release. It never
  # copies a path, capability, payload, header, query, source token, or client address.
  plug(BurnerpadWeb.RequestLogger)

  plug(Plug.Parsers,
    parsers: [:json],
    # `pass: []` ⇒ any non-JSON body is rejected with 415 (L3). This is ALSO the CSRF gate (M2): a
    # cross-site "simple request" POST cannot set Content-Type: application/json, so a forged burn/reveal
    # is refused before it runs, on every browser.
    pass: [],
    json_decoder: JSON,
    # Cap the body BEFORE buffering: the only body we accept is a ~64 KB ciphertext blob
    # (base64url ~88 KB + small JSON overhead). Reject anything larger up front.
    length: 100_000,
    read_length: 100_000,
    read_timeout: 10_000,
    query_string_length: 1_000
  )

  plug(:match)
  plug(:dispatch)

  ## ── routes ──────────────────────────────────────────────────────────────

  get "/" do
    # One aggregate UTC-day counter only. This is intentionally a page-view count, not a unique-person
    # metric: uniqueness would require retaining a cookie, fingerprint, or network identifier.
    DailyStats.record_homepage_view()
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

  # Atomic take for at most one handler. POST (not a burning GET) so ordinary link-preview bots can't
  # destroy a shared secret, and under `/api` behind the content-type CSRF gate (M2).
  post "/api/secrets/:id/reveal" do
    case Store.reveal(id) do
      {:ok, blob} -> json(conn, 200, %{blob: Base.url_encode64(blob, padding: false)})
      :gone -> json(conn, 404, %{error: "not found"})
    end
  end

  # Manual revoke with the management token.
  post "/api/secrets/:id/burn" do
    case Store.burn(id, conn.body_params["mgmt_token"]) do
      :ok -> json(conn, 200, %{status: "burned"})
      :error -> json(conn, 404, %{error: "not found or invalid token"})
    end
  end

  # Store an opaque ciphertext blob.
  post "/api/secrets" do
    max_blob = Config.get(:max_blob)
    key = ClientIP.get(conn)

    with {:ok, ttl} <- effective_ttl(conn.body_params),
         b64 when is_binary(b64) <- conn.body_params["blob"],
         {:ok, blob} <- Encoding.decode64url(b64),
         size when size > 0 and size <= max_blob <- byte_size(blob),
         # Per-IP capacity budget — checked here (the router has the abuse key) so Store stays IP-free.
         {:ok, id, mgmt} <- create_with_budget(key, blob, ttl) do
      json(conn, 200, %{id: id, mgmt_token: mgmt, ttl: ttl})
    else
      {:error, :full} ->
        json(conn, 503, %{error: "service full, try again later"})

      {:error, :over_budget} ->
        json(conn, 429, %{error: "too many secrets from your address, try again later"})

      {:error, {:global_create, retry_ms}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(retry_ms, 1000) + 1))
        |> json(503, %{error: "service busy, try again later"})

      {:error, :busy} ->
        json(conn, 503, %{error: "service busy, try again later"})

      {:error, :invalid_ttl} ->
        json(conn, 400, %{error: "invalid ttl", code: "invalid_ttl"})

      _ ->
        json(conn, 400, %{error: "invalid blob"})
    end
  end

  # (The old burning `GET /api/secrets/:id` is removed: no endpoint destroys a secret on a GET, so GETs are
  # safe/idempotent again and a prefetch can't burn anything. CLI/scripts use `POST /api/secrets/:id/reveal`
  # with `Content-Type: application/json`.)

  # Public, exact/live aggregate transparency — capability-free counts, nothing about a secret or user.
  get "/stats" do
    html(conn, 200, Pages.stats(stats_map()))
  end

  get "/api/stats" do
    json(conn, 200, stats_map())
  end

  # Public delivery-contract probe. The caller supplies the address independently observed at Cloudflare's
  # edge; the response reveals only whether this deployed trusted-proxy path resolved the same /32 or /64.
  # It never returns or retains either address, and the JSON-only POST prevents a cross-site simple request.
  post "/api/edge/source-check" do
    case ClientIP.compare(conn, conn.body_params["expected_ip"]) do
      :match -> empty(conn, 204)
      :mismatch -> empty(conn, 409)
      :invalid -> json(conn, 400, %{error: "invalid expected IP"})
    end
  end

  # Public Terms & Acceptable-Use (a template rendered with operator placeholders from config).
  get "/terms" do
    html(conn, 200, Pages.terms())
  end

  get "/.well-known/security.txt" do
    expires = DateTime.utc_now() |> DateTime.add(180, :day) |> DateTime.to_iso8601()

    body = """
    Contact: mailto:#{Config.security_email()}
    Expires: #{expires}
    Preferred-Languages: en
    Policy: #{Config.security_policy_url()}
    """

    text(conn, 200, body)
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  ## ── helpers ─────────────────────────────────────────────────────────────

  # Liveness proves only that the HTTP VM can answer. Readiness composes the bounded Store and Abuse
  # interfaces; each owner verifies its own process and private ETS state. GET and HEAD are the complete
  # safe method surface; mutation methods continue through the normal narrow HTTP surface. The connection
  # adapter suppresses the response body for HEAD.
  defp healthz(%Plug.Conn{method: method, request_path: "/healthz"} = conn, _opts)
       when method in ["GET", "HEAD"] do
    conn |> text(200, "ok") |> halt()
  end

  defp healthz(%Plug.Conn{method: method, request_path: "/readyz"} = conn, _opts)
       when method in ["GET", "HEAD"] do
    ready? = Store.ready?() and Abuse.ready?()

    if ready?,
      do: conn |> text(200, "ready") |> halt(),
      else: conn |> text(503, "not ready") |> halt()
  end

  defp healthz(conn, _opts), do: conn

  # Reserve the per-source budget before touching Store. If Store is at capacity, roll back the opaque
  # reservation so repeated 503 responses cannot consume a client's budget without storing ciphertext.
  defp create_with_budget(key, blob, ttl) do
    bytes = byte_size(blob)

    with {:ok, reservation} <- Abuse.admit_create(key, bytes, ttl) do
      case Store.create(blob, ttl) do
        {:ok, _id, _mgmt} = created ->
          created

        error ->
          Abuse.rollback_create(reservation)
          error
      end
    end
  end

  # Missing TTL uses the configured default. A present integer is clamped to the documented interval and
  # returned to the caller; a present value of any other JSON type fails closed instead of silently
  # extending retention to the default (normally the 24-hour maximum).
  defp effective_ttl(params) do
    case Map.fetch(params, "ttl") do
      :error ->
        {:ok, Config.get(:ttl_seconds)}

      {:ok, ttl} when is_integer(ttl) ->
        {:ok, ttl |> max(60) |> min(Config.get(:ttl_seconds))}

      {:ok, _invalid} ->
        {:error, :invalid_ttl}
    end
  end

  defp stats_map do
    Store.metrics()
    |> Map.merge(Abuse.metrics())
    # Keep the established `daily_visits` API key compatible; each row now also carries the successful
    # secret-creation count for the same UTC day.
    |> Map.put(:daily_visits, DailyStats.daily())
    |> Map.put(:version, Config.version())
    |> Map.put(:image_digest, Config.image_digest())
  end

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

  defp text(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> SecurityHeaders.no_store()
    |> send_resp(status, body)
  end

  defp empty(conn, status) do
    conn
    |> SecurityHeaders.no_store()
    |> send_resp(status, "")
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: reason}) do
    status = if is_exception(reason), do: Plug.Exception.status(reason), else: conn.status || 500
    # Generic message only — never leak internals/stack traces to the client.
    # Exception messages can contain request data. Keep the disk-bound log deliberately generic.
    if status >= 500 do
      Store.record_internal_error()

      Logger.error(
        "request_failed status=#{status} route=#{RouteClass.classify(conn.path_info)} release=#{Config.version()}"
      )
    end

    conn
    # Plug.ErrorHandler receives the pre-pipeline connection, so headers set by the first plug are not
    # present here after a parser/router exception. Reapply the shared policy at the error boundary.
    |> SecurityHeaders.call([])
    |> put_resp_content_type("application/json")
    |> SecurityHeaders.no_store()
    |> send_resp(status, JSON.encode!(%{error: "request failed"}))
  end
end
