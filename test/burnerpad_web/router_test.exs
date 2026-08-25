# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.RouterTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  import Burnerpad.Support
  import ExUnit.CaptureLog

  setup do
    reset()
    :ok
  end

  ## ── helpers ──────────────────────────────────────────────────────────────

  defp post_json(path, map, ip \\ {127, 0, 0, 1}) do
    %{conn(:post, path, JSON.encode!(map)) | remote_ip: ip}
    |> put_req_header("content-type", "application/json")
    |> call()
  end

  defp create_secret(blob) do
    conn = post_json("/api/secrets", %{blob: Base.url_encode64(blob, padding: false)})
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp get_as(path, ip), do: %{conn(:get, path) | remote_ip: ip} |> call()

  ## ── the create page ──────────────────────────────────────────────────────

  test "GET / pins every active asset, has no inline scripts, and sends strict hardening headers" do
    conn = conn(:get, "/") |> call()
    assert conn.status == 200
    body = conn.resp_body

    assert body =~ "Encrypt"

    # the create button is always active; its label starts as an invitation and JS flips it on first input
    assert body =~ "Add your secret to continue"
    assert body =~ "burnerpad-crypto.js"

    # CSS + theme bootstrap + two crypto scripts — all external + SRI-pinned, none inline
    integrities = Regex.scan(~r/integrity="(sha384-[^"]+)"/, body) |> Enum.map(&List.last/1)
    assert length(integrities) == 4
    assert body =~ ~s(src="/crypto/theme.js")

    # no inline <script> with a body — every script is an external src
    refute body =~ ~r/<script(?![^>]*\bsrc=)[^>]*>\s*\S/

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'none'"
    assert csp =~ "script-src 'self'"
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-permitted-cross-domain-policies") == ["none"]
    assert [hsts] = get_resp_header(conn, "strict-transport-security")
    assert hsts =~ "max-age="
    assert get_resp_header(conn, "cross-origin-resource-policy") == ["same-origin"]
    assert body =~ ~s(href="/terms")
  end

  ## ── create / reveal / burn ───────────────────────────────────────────────

  test "create -> non-burning GET interstitial -> reveal once -> indistinguishable 404" do
    %{"id" => id} = create_secret(<<7, 7, 7>>)

    g = conn(:get, "/s/#{id}") |> call()
    assert g.status == 200
    assert g.resp_body =~ ~s(id="bp-psk-reveal")
    assert g.resp_body =~ ~s(data-id="#{id}")
    assert get_resp_header(g, "cache-control") == ["no-store"]

    r = post_json("/api/secrets/#{id}/reveal", %{})
    assert r.status == 200
    assert JSON.decode!(r.resp_body)["blob"] == Base.url_encode64(<<7, 7, 7>>, padding: false)

    r2 = post_json("/api/secrets/#{id}/reveal", %{})
    assert r2.status == 404
  end

  test "burn revokes with the right token and rejects a wrong one" do
    %{"id" => id, "mgmt_token" => mgmt} = create_secret(<<3>>)
    wrong = post_json("/api/secrets/#{id}/burn", %{mgmt_token: "wrong"})
    absent = post_json("/api/secrets/#{String.duplicate("Z", 26)}/burn", %{mgmt_token: "wrong"})
    assert wrong.status == 404
    assert absent.status == 404
    assert wrong.resp_body == absent.resp_body
    assert post_json("/api/secrets/#{id}/burn", %{mgmt_token: mgmt}).status == 200
    assert post_json("/api/secrets/#{id}/burn", %{mgmt_token: mgmt}).status == 404
    assert post_json("/api/secrets/#{id}/reveal", %{}).status == 404
  end

  test "the server is crypto-agnostic: a suite-0x02 (PSK) blob round-trips through the API" do
    psk = <<0x02>> <> :crypto.strong_rand_bytes(16 + 12 + 40)
    %{"id" => id} = create_secret(psk)
    r = post_json("/api/secrets/#{id}/reveal", %{})
    assert Base.url_decode64!(JSON.decode!(r.resp_body)["blob"], padding: false) == psk
  end

  ## ── input limits ─────────────────────────────────────────────────────────

  test "rejects an empty blob and an oversized (>64 KB) blob with 400" do
    assert post_json("/api/secrets", %{blob: ""}).status == 400

    big = Base.url_encode64(:binary.copy(<<0>>, 64 * 1024 + 1), padding: false)
    assert post_json("/api/secrets", %{blob: big}).status == 400
  end

  test "create transport accepts only canonical unpadded base64url" do
    assert post_json("/api/secrets", %{blob: "AQ"}).status == 200

    for invalid <- ["AR", "AQ==", "AQ\n", "AQ+", "A"] do
      assert post_json("/api/secrets", %{blob: invalid}).status == 400
    end
  end

  test "TTL absence/default, clamping, and invalid supplied types are explicit" do
    put_config(:ttl_seconds, 3600)
    blob = Base.url_encode64(<<1>>, padding: false)

    for {body, expected} <- [
          {%{blob: blob}, 3600},
          {%{blob: blob, ttl: 60}, 60},
          {%{blob: blob, ttl: 3600}, 3600},
          {%{blob: blob, ttl: 1}, 60},
          {%{blob: blob, ttl: 3601}, 3600}
        ] do
      response =
        post_json("/api/secrets", body, {198, 51, expected |> div(256), rem(expected, 256)})

      assert response.status == 200
      assert JSON.decode!(response.resp_body)["ttl"] == expected
    end

    for invalid <- ["60", 60.0, true, false, %{"seconds" => 60}, nil] do
      response = post_json("/api/secrets", %{blob: blob, ttl: invalid})
      assert response.status == 400

      assert JSON.decode!(response.resp_body) == %{
               "code" => "invalid_ttl",
               "error" => "invalid ttl"
             }
    end
  end

  test "global valid-create ceiling sheds distributed creation with a bounded retry" do
    put_config(:global_create_ceiling, 1)
    blob = Base.url_encode64(<<1>>, padding: false)

    assert post_json("/api/secrets", %{blob: blob}, {198, 51, 100, 1}).status == 200
    rejected = post_json("/api/secrets", %{blob: blob}, {198, 51, 100, 2})
    assert rejected.status == 503
    assert [_] = get_resp_header(rejected, "retry-after")
    assert JSON.decode!(rejected.resp_body)["error"] == "service busy, try again later"
  end

  test "a request body over the parser cap is rejected before buffering" do
    huge = ~s({"blob":") <> String.duplicate("A", 120_000) <> ~s("})

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      %{conn(:post, "/api/secrets", huge) | remote_ip: {127, 0, 0, 1}}
      |> put_req_header("content-type", "application/json")
      |> call()
    end
  end

  test "create rejects with 503 once MAX_SECRETS is reached (never evicting)" do
    put_config(:max_secrets, 1)
    assert {:ok, _id, _token} = Burnerpad.Store.create(<<1>>)
    full = post_json("/api/secrets", %{blob: Base.url_encode64(<<2>>, padding: false)})

    assert full.status == 503
  end

  test "a capacity rejection does not consume the source's row or byte budget" do
    put_config(:max_secrets, 1)
    put_config(:per_ip_budget, 2)
    put_config(:per_ip_row_budget, 2)
    blob = Base.url_encode64(<<1>>, padding: false)
    ip = {203, 0, 113, 44}

    assert post_json("/api/secrets", %{blob: blob}, ip).status == 200
    assert post_json("/api/secrets", %{blob: blob}, ip).status == 503

    # Isolate the budget assertion: removing the stored row creates capacity. This request fits only if
    # the failed request rolled both its row and byte reservations back.
    Burnerpad.Store.reset()
    assert post_json("/api/secrets", %{blob: blob}, ip).status == 200
  end

  ## ── abuse / rate limiting through the pipeline ────────────────────────────

  test "the flat per-IP rate limit counts every request and returns 429" do
    put_config(:rate_limit, 2)
    put_config(:ban_threshold, 1000)
    ip = {203, 0, 113, 7}
    assert get_as("/", ip).status == 200
    assert get_as("/", ip).status == 200
    assert get_as("/", ip).status == 429
  end

  test "M13: per-IP byte budget throttles one source with 429; a different source is unaffected" do
    put_config(:per_ip_budget, 100)
    blob = Base.url_encode64(<<2>> <> :binary.copy(<<0>>, 47), padding: false)
    ip = {198, 51, 100, 5}
    assert post_json("/api/secrets", %{blob: blob}, ip).status == 200
    assert post_json("/api/secrets", %{blob: blob}, ip).status == 200
    over = post_json("/api/secrets", %{blob: blob}, ip)
    assert over.status == 429
    assert JSON.decode!(over.resp_body)["error"] =~ "address"
    # a different source has its own budget
    assert post_json("/api/secrets", %{blob: blob}, {198, 51, 100, 6}).status == 200
  end

  ## ── static assets + SRI integrity ─────────────────────────────────────────

  test "crypto assets are served and their SRI matches the bytes pinned on the page" do
    page = conn(:get, "/") |> call()

    integrities =
      Regex.scan(~r/integrity="(sha384-[^"]+)"/, page.resp_body) |> Enum.map(&List.last/1)

    for {url, file} <- [
          {"/crypto/burnerpad-crypto.js", "priv/static/vendor/crypto-js/burnerpad-crypto.js"},
          {"/crypto/crypto-app.js", "priv/static/crypto/crypto-app.js"},
          {"/crypto/theme.js", "priv/static/crypto/theme.js"},
          {"/crypto/crypto.css", "priv/static/crypto/crypto.css"}
        ] do
      assert conn(:get, url) |> call() |> Map.fetch!(:status) == 200
      computed = "sha384-" <> Base.encode64(:crypto.hash(:sha384, File.read!(file)))
      assert computed in integrities, "SRI for #{url} not present/matching on the page"
    end

    # stable-path assets pinned by SRI must revalidate (never immutable) — otherwise a returning
    # browser serves a stale script that the page's fresh SRI hash then blocks, breaking the UI
    cc = conn(:get, "/crypto/crypto-app.js") |> call() |> get_resp_header("cache-control")
    assert cc != []
    refute Enum.any?(cc, &String.contains?(&1, "immutable"))

    first = conn(:get, "/crypto/crypto-app.js") |> call()
    [etag] = get_resp_header(first, "etag")

    conditional =
      conn(:get, "/crypto/crypto-app.js")
      |> put_req_header("if-none-match", etag)
      |> call()

    assert conditional.status == 304
    assert conditional.resp_body == ""
    assert get_resp_header(conditional, "etag") == [etag]
  end

  test "security headers are present on JSON responses too" do
    r = post_json("/api/secrets/MISSING01/reveal", %{})
    assert r.status == 404
    assert get_resp_header(r, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(r, "content-type") |> hd() =~ "application/json"
    assert get_resp_header(r, "cache-control") == ["no-store"]
  end

  # The shared Layout chrome means this is ONE assertion across every page, not five per-page checks.
  test "every page emits the Layout chrome (theme bootstrap + header + sprite + footer, no inline scripts)" do
    %{"id" => id} = create_secret(<<1>>)
    crypto_pages = [conn(:get, "/") |> call(), conn(:get, "/s/#{id}") |> call()]

    light_pages = [
      conn(:get, "/s/ZZZZZZZZ") |> call(),
      conn(:get, "/stats") |> call(),
      conn(:get, "/terms") |> call()
    ]

    for p <- crypto_pages ++ light_pages do
      # render-blocking theme bootstrap, every page
      assert p.resp_body =~ ~s(src="/crypto/theme.js")
      # site header
      assert p.resp_body =~ "data-theme-toggle"
      # icon sprite
      assert p.resp_body =~ ~s(<symbol id="i-logo")
      # footer
      assert p.resp_body =~ ~s(<footer class="footer")
      # no inline scripts anywhere
      refute p.resp_body =~ ~r/<script(?![^>]*\bsrc=)[^>]*>\s*\S/
    end

    # only the crypto pages carry the two extra SRI-pinned crypto scripts; the script-light pages do not
    for p <- crypto_pages, do: assert(p.resp_body =~ ~s(src="/crypto/crypto-app.js"))
    for p <- light_pages, do: refute(p.resp_body =~ ~s(src="/crypto/crypto-app.js"))
  end

  test "cache-control: no-store is the secure default everywhere (incl. the abuse short-circuit); static assets opt out" do
    # a dynamic HTML page
    assert get_resp_header(conn(:get, "/") |> call(), "cache-control") == ["no-store"]

    # the one-time reveal ciphertext must never be cached
    %{"id" => id} = create_secret(<<9, 9, 9>>)
    rev = post_json("/api/secrets/#{id}/reveal", %{})
    assert rev.status == 200
    assert get_resp_header(rev, "cache-control") == ["no-store"]

    # the create response carries the single-use mgmt_token — also no-store
    cre = post_json("/api/secrets", %{blob: Base.url_encode64(<<1>>, padding: false)})
    assert get_resp_header(cre, "cache-control") == ["no-store"]

    # static assets OPT OUT: they never call no_store/1, so Plug.Static keeps them cacheable
    # (ETag-revalidated) — the SRI-pinned scripts/CSS must NOT be no-store or they'd refetch every load.
    # (Checked before the rate-limit drop below, or the asset request would itself be a 429.)
    css = conn(:get, "/crypto/crypto.css") |> call()
    assert css.status == 200
    css_cc = get_resp_header(css, "cache-control")
    assert css_cc != []
    refute "no-store" in css_cc

    # the abuse 429 short-circuit bypasses the html/json helpers yet STILL carries no-store — because the
    # reject path also routes through the one shared SecurityHeaders.no_store/1 policy
    put_config(:rate_limit, 1)
    put_config(:ban_threshold, 1000)
    ip = {203, 0, 113, 41}
    get_as("/", ip)
    limited = get_as("/", ip)
    assert limited.status == 429
    assert get_resp_header(limited, "cache-control") == ["no-store"]
  end

  test "unknown routes return a JSON 404" do
    r = conn(:get, "/nope") |> call()
    assert r.status == 404
  end

  test "request/error logs retain safe operations data without paths or exception text" do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)
    path_marker = "PRIVATE-PATH-MARKER"

    path_log =
      capture_log([level: :info], fn ->
        assert conn(:get, "/anything/#{path_marker}") |> call() |> Map.fetch!(:status) == 404
      end)

    assert path_log =~ "request method=GET route=unmatched status=404 duration_ms="
    assert path_log =~ "release=#{Burnerpad.Config.version()}"
    refute path_log =~ path_marker

    error_marker = "PRIVATE-ERROR-MARKER"

    error_log =
      capture_log(fn ->
        conn(:get, "/")
        |> BurnerpadWeb.Router.handle_errors(%{reason: RuntimeError.exception(error_marker)})
      end)

    assert error_log =~ "request_failed status=500 route=home"
    refute error_log =~ error_marker

    error_response =
      conn(:get, "/")
      |> BurnerpadWeb.Router.handle_errors(%{reason: RuntimeError.exception(error_marker)})

    assert get_resp_header(error_response, "content-security-policy") != []
    assert get_resp_header(error_response, "strict-transport-security") != []
    assert get_resp_header(error_response, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(error_response, "cache-control") == ["no-store"]
  end

  ## ── programmatic API ─────────────────────────────────────────────────────

  test "the burning GET is gone; POST reveal has at most one successful claimant" do
    %{"id" => id} = create_secret(<<5, 5, 5>>)
    # the old burning GET no longer exists — a GET must never destroy a secret (un-prefetchable)
    assert conn(:get, "/api/secrets/#{id}") |> call() |> Map.fetch!(:status) == 404
    # the POST take burns once, then returns the same 404 as every unavailable id
    r = post_json("/api/secrets/#{id}/reveal", %{})
    assert r.status == 200
    assert Base.url_decode64!(JSON.decode!(r.resp_body)["blob"], padding: false) == <<5, 5, 5>>
    assert post_json("/api/secrets/#{id}/reveal", %{}).status == 404
  end

  test "CSRF gate: a mutating POST without Content-Type: application/json is rejected with 415 (L3/M2)" do
    %{"id" => id} = create_secret(<<6, 6, 6>>)

    # A cross-site "simple request" POST can't set application/json. `pass: []` rejects it in Plug.Parsers
    # (the error handler turns that into a 415 to the client) BEFORE the reveal handler runs.
    assert Plug.Exception.status(%Plug.Parsers.UnsupportedMediaTypeError{
             media_type: "text/plain"
           }) == 415

    assert_raise Plug.Parsers.UnsupportedMediaTypeError, fn ->
      %{conn(:post, "/api/secrets/#{id}/reveal", "") | remote_ip: {127, 0, 0, 1}}
      |> put_req_header("content-type", "text/plain")
      |> call()
    end

    # the secret is UNTOUCHED — the forged burn never ran
    assert post_json("/api/secrets/#{id}/reveal", %{}).status == 200
  end

  test "GET /healthz is a plain 200 and is not rate-limited (served above AbusePlug)" do
    put_config(:rate_limit, 1)
    put_config(:ban_threshold, 1000)
    ip = {203, 0, 113, 99}
    assert get_as("/healthz", ip).status == 200
    assert get_as("/healthz", ip).status == 200
    assert get_as("/healthz", ip).status == 200
  end

  test "health endpoints accept GET and HEAD while rejecting mutation methods" do
    for {path, expected_body} <- [{"/healthz", "ok"}, {"/readyz", "ready"}] do
      get_response = conn(:get, path) |> call()
      assert get_response.status == 200
      assert get_response.resp_body == expected_body
      assert get_resp_header(get_response, "cache-control") == ["no-store"]

      head_response = conn(:head, path) |> call()
      assert head_response.status == get_response.status
      assert head_response.resp_body == ""
      assert get_resp_header(head_response, "cache-control") == ["no-store"]

      assert get_resp_header(head_response, "content-type") ==
               get_resp_header(get_response, "content-type")

      for method <- [:post, :put, :patch, :delete] do
        assert (conn(method, path, "") |> call()).status == 404
      end
    end
  end

  test "readiness fails within a bound when a critical state owner is stalled" do
    put_config(:state_call_timeout_ms, 100)
    :sys.suspend(Burnerpad.Store)

    on_exit(fn ->
      try do
        :sys.resume(Burnerpad.Store)
      catch
        :exit, _ -> :ok
      end
    end)

    for method <- [:get, :head] do
      started = System.monotonic_time(:millisecond)
      response = conn(method, "/readyz") |> call()
      assert response.status == 503
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert System.monotonic_time(:millisecond) - started < 1_000
    end
  end

  ## ── public stats ─────────────────────────────────────────────────────────

  test "GET /stats is public and /api/stats returns aggregate metrics" do
    create_secret(<<1, 2>>)
    conn(:get, "/") |> call()
    conn(:get, "/") |> call()

    page = conn(:get, "/stats") |> call()
    assert page.status == 200
    assert page.resp_body =~ "Transparency"
    assert page.resp_body =~ "resident ciphertexts"
    assert page.resp_body =~ "Daily activity"
    assert page.resp_body =~ "Homepage requests and successful secret creations"
    assert page.resp_body =~ "secrets created today"
    assert page.resp_body =~ ~s(<svg class="activity-plot")
    assert page.resp_body =~ "Grouped bar chart for the last 14 UTC days"
    assert page.resp_body =~ ~s(<div class="sr-only">)
    assert page.resp_body =~ "2 homepage visits on"
    assert page.resp_body =~ "1 secrets created on"
    refute page.resp_body =~ "<progress"
    assert page.resp_body =~ "Version"
    assert page.resp_body =~ Burnerpad.Config.version()
    refute page.resp_body =~ "UTC · 14 days"

    j = conn(:get, "/api/stats") |> call()
    assert j.status == 200
    m = JSON.decode!(j.resp_body)
    assert m["created"] >= 1
    assert m["stored"] >= 1
    assert Map.has_key?(m, "throttled_total")
    assert Map.has_key?(m, "active_bans")
    assert m["version"] == Burnerpad.Config.version()

    assert [%{"date" => _, "visits" => 2, "secrets_created" => 1} | _] =
             Enum.reverse(m["daily_visits"])

    # privacy: the stats payload must not contain any per-secret/per-user identifiers
    refute Map.has_key?(m, "key")
    refute page.resp_body =~ "unique visitors"
    assert page.resp_body =~ "No contents, IDs, IPs, cookies, or visitor identifiers"
  end

  test "source check compares the deployed resolver without returning a source identifier" do
    put_config(:trusted_proxies, Burnerpad.Config.parse_proxy_cidrs!("10.0.0.0/8"))

    request = fn expected ->
      %{
        conn(:post, "/api/edge/source-check", JSON.encode!(%{expected_ip: expected}))
        | remote_ip: {10, 1, 2, 3}
      }
      |> put_req_header("content-type", "application/json")
      |> put_req_header(Burnerpad.Config.real_ip_header(), "203.0.113.7")
      |> call()
    end

    matched = request.("203.0.113.7")
    assert matched.status == 204
    assert matched.resp_body == ""
    assert get_resp_header(matched, "cache-control") == ["no-store"]

    mismatched = request.("203.0.113.8")
    assert mismatched.status == 409
    assert mismatched.resp_body == ""
    refute mismatched.resp_body =~ "203.0.113"

    invalid = request.("not-an-ip")
    assert invalid.status == 400
    assert JSON.decode!(invalid.resp_body) == %{"error" => "invalid expected IP"}
    refute invalid.resp_body =~ "not-an-ip"

    assert_raise Plug.Parsers.UnsupportedMediaTypeError, fn ->
      %{
        conn(:post, "/api/edge/source-check", ~s({"expected_ip":"203.0.113.7"}))
        | remote_ip: {10, 1, 2, 3}
      }
      |> put_req_header("content-type", "text/plain")
      |> call()
    end
  end

  test "source check ignores a forged forwarding header from an untrusted peer" do
    put_config(:trusted_proxies, [])

    response =
      %{
        conn(:post, "/api/edge/source-check", JSON.encode!(%{expected_ip: "198.51.100.5"}))
        | remote_ip: {198, 51, 100, 5}
      }
      |> put_req_header("content-type", "application/json")
      |> put_req_header(Burnerpad.Config.real_ip_header(), "192.0.2.1")
      |> call()

    assert response.status == 204
    assert response.resp_body == ""
  end

  test "security.txt is rendered from operator config with a bounded future expiry" do
    put_config(:security_email, "security@example.com")
    put_config(:security_policy_url, "https://example.com/security")
    response = conn(:get, "/.well-known/security.txt") |> call()

    assert response.status == 200
    assert response.resp_body =~ "Contact: mailto:security@example.com"
    assert response.resp_body =~ "Policy: https://example.com/security"
    [expires] = Regex.run(~r/^Expires: (.+)$/m, response.resp_body, capture: :all_but_first)
    {:ok, expires_at, _offset} = DateTime.from_iso8601(expires)
    days = DateTime.diff(expires_at, DateTime.utc_now(), :day)
    assert days >= 179 and days <= 180
  end

  ## ── terms ────────────────────────────────────────────────────────────────

  test "GET /terms is public and renders the operator's filled-in terms (no template warning)" do
    # Operator identity is required (M7 — no hard-coded default); a prod boot supplies it via env, and here
    # we set it explicitly. The point of the test is that it renders filled-in, not bracketed placeholders.
    put_config(:operator_name, "Impulsa SLU")
    put_config(:abuse_email, "abuse@burnerpad.io")
    r = conn(:get, "/terms") |> call()
    assert r.status == 200
    body = r.resp_body
    assert body =~ "Acceptable use"
    assert body =~ "Limitation of liability"
    assert body =~ "Impulsa SLU"
    assert body =~ "abuse@burnerpad.io"
    refute body =~ "Template — not legal advice"
    refute body =~ "[abuse@your-domain]"
  end

  test "operator placeholders on /terms are filled from config" do
    put_config(:abuse_email, "abuse@example.com")
    put_config(:operator_name, "Acme Inc")
    body = conn(:get, "/terms") |> call() |> Map.fetch!(:resp_body)
    assert body =~ "abuse@example.com"
    assert body =~ "Acme Inc"
    refute body =~ "[abuse@your-domain]"
  end

  test "terms describe anonymous abuse controls without promising individual exclusion" do
    body = conn(:get, "/terms") |> call() |> Map.fetch!(:resp_body)

    assert body =~ "Abuse controls"
    assert body =~ "per-network-source"
    assert body =~ "temporary bans"
    assert body =~ "shared NAT/CGNAT"
    assert body =~ "distributed actors"
    assert body =~ "do not identify an individual or guarantee permanent exclusion"
    assert body =~ "no source-to-secret mapping"
    refute body =~ "permanently ban"
    refute body =~ "suspend any user"
  end

  ## ── passphrase-only UI is present ─────────────────────────────────────────

  test "create page shows the generated chips + hand-pick combo; reveal page is the chip input only" do
    home = conn(:get, "/") |> call()

    # passphrase block is always present (no opt-in disclosure); chips render on load via the driver
    assert home.resp_body =~ ~s(id="bp-pass-field")
    assert home.resp_body =~ ~s(id="bp-pass-chips")
    assert home.resp_body =~ ~s(id="bp-pass-input")
    assert home.resp_body =~ ~s(id="bp-pass-regen")
    assert home.resp_body =~ ~s(aria-expanded="false")
    # no tabs / link-mode / old toggle remnants
    refute home.resp_body =~ ~s(id="bp-pass-toggle")
    refute home.resp_body =~ ~s(id="bp-pass-choose")
    refute home.resp_body =~ ~s(id="bp-mode-gen")

    %{"id" => id} = create_secret(<<1>>)
    view = conn(:get, "/s/#{id}") |> call()

    # purist reveal: the chip/autocomplete input + the unsupported-link section, no link-mode interstitial
    assert view.resp_body =~ ~s(id="bp-psk-reveal")
    assert view.resp_body =~ ~s(id="bp-psk-chips")
    assert view.resp_body =~ ~s(id="bp-unsupported")
    refute view.resp_body =~ ~s(id="bp-reveal")
    refute view.resp_body =~ ~s(id="bp-interstitial")
  end
end
