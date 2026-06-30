# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.RouterTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  import Burnerpad.Support

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

  test "GET / serves the create page: three SRI scripts, no inline scripts, strict CSP + hardening" do
    conn = conn(:get, "/") |> call()
    assert conn.status == 200
    body = conn.resp_body

    assert body =~ "Encrypt"

    # the create button is always active; its label starts as an invitation and JS flips it on first input
    assert body =~ "Add your secret to continue"
    assert body =~ "burnerpad-crypto.js"

    # theme bootstrap (head) + the two crypto scripts — all external + SRI-pinned, none inline
    integrities = Regex.scan(~r/integrity="(sha384-[^"]+)"/, body) |> Enum.map(&List.last/1)
    assert length(integrities) == 3
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

  test "create -> non-burning GET interstitial -> reveal once -> 410" do
    %{"id" => id} = create_secret(<<7, 7, 7>>)

    g = conn(:get, "/s/#{id}") |> call()
    assert g.status == 200
    assert g.resp_body =~ ~s(id="bp-psk-reveal")
    assert g.resp_body =~ ~s(data-id="#{id}")
    assert get_resp_header(g, "cache-control") == ["no-store"]

    r = conn(:post, "/s/#{id}/reveal") |> call()
    assert r.status == 200
    assert JSON.decode!(r.resp_body)["blob"] == Base.url_encode64(<<7, 7, 7>>, padding: false)

    r2 = conn(:post, "/s/#{id}/reveal") |> call()
    assert r2.status == 410
  end

  test "burn revokes with the right token and rejects a wrong one" do
    %{"id" => id, "mgmt_token" => mgmt} = create_secret(<<3>>)
    assert post_json("/s/#{id}/burn", %{mgmt_token: "wrong"}).status == 403
    assert post_json("/s/#{id}/burn", %{mgmt_token: mgmt}).status == 200
    assert conn(:post, "/s/#{id}/reveal") |> call() |> Map.fetch!(:status) == 410
  end

  test "report is non-destructive and never leaks existence" do
    %{"id" => id} = create_secret(<<8>>)
    assert conn(:post, "/s/#{id}/report") |> call() |> Map.fetch!(:status) == 200
    # still revealable
    assert conn(:post, "/s/#{id}/reveal") |> call() |> Map.fetch!(:status) == 200
    # unknown id also 200
    assert conn(:post, "/s/UNKNOWN01/report") |> call() |> Map.fetch!(:status) == 200
  end

  test "the server is crypto-agnostic: a suite-0x02 (PSK) blob round-trips through the API" do
    psk = <<0x02>> <> :crypto.strong_rand_bytes(16 + 12 + 40)
    %{"id" => id} = create_secret(psk)
    r = conn(:post, "/s/#{id}/reveal") |> call()
    assert Base.url_decode64!(JSON.decode!(r.resp_body)["blob"], padding: false) == psk
  end

  ## ── input limits ─────────────────────────────────────────────────────────

  test "rejects an empty blob and an oversized (>64 KB) blob with 400" do
    assert post_json("/api/secrets", %{blob: ""}).status == 400

    big = Base.url_encode64(:binary.copy(<<0>>, 64 * 1024 + 1), padding: false)
    assert post_json("/api/secrets", %{blob: big}).status == 400
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
    create_secret(<<1>>)
    full = post_json("/api/secrets", %{blob: Base.url_encode64(<<2>>, padding: false)})
    assert full.status == 503
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

  ## ── static assets + SRI integrity ─────────────────────────────────────────

  test "both crypto scripts are served and their SRI matches the bytes pinned on the page" do
    page = conn(:get, "/") |> call()

    integrities =
      Regex.scan(~r/integrity="(sha384-[^"]+)"/, page.resp_body) |> Enum.map(&List.last/1)

    for {url, file} <- [
          {"/crypto/burnerpad-crypto.js", "priv/static/vendor/crypto-js/burnerpad-crypto.js"},
          {"/crypto/crypto-app.js", "priv/static/crypto/crypto-app.js"},
          {"/crypto/theme.js", "priv/static/crypto/theme.js"}
        ] do
      assert conn(:get, url) |> call() |> Map.fetch!(:status) == 200
      computed = "sha384-" <> Base.encode64(:crypto.hash(:sha384, File.read!(file)))
      assert computed in integrities, "SRI for #{url} not present/matching on the page"
    end

    assert conn(:get, "/crypto/crypto.css") |> call() |> Map.fetch!(:status) == 200

    # stable-path assets pinned by SRI must revalidate (never immutable) — otherwise a returning
    # browser serves a stale script that the page's fresh SRI hash then blocks, breaking the UI
    cc = conn(:get, "/crypto/crypto-app.js") |> call() |> get_resp_header("cache-control")
    assert cc != []
    refute Enum.any?(cc, &String.contains?(&1, "immutable"))
  end

  test "security headers are present on JSON responses too" do
    r = conn(:post, "/s/MISSING01/reveal") |> call()
    assert r.status == 410
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
    rev = conn(:post, "/s/#{id}/reveal") |> call()
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

  ## ── programmatic API ─────────────────────────────────────────────────────

  test "GET /api/secrets/:id takes (burns) the blob exactly once" do
    %{"id" => id} = create_secret(<<5, 5, 5>>)
    r = conn(:get, "/api/secrets/#{id}") |> call()
    assert r.status == 200
    assert Base.url_decode64!(JSON.decode!(r.resp_body)["blob"], padding: false) == <<5, 5, 5>>
    assert conn(:get, "/api/secrets/#{id}") |> call() |> Map.fetch!(:status) == 410
  end

  ## ── public stats ─────────────────────────────────────────────────────────

  test "GET /stats is public and /stats.json returns aggregate metrics" do
    create_secret(<<1, 2>>)

    page = conn(:get, "/stats") |> call()
    assert page.status == 200
    assert page.resp_body =~ "Transparency"
    assert page.resp_body =~ "live secrets"

    j = conn(:get, "/stats.json") |> call()
    assert j.status == 200
    m = JSON.decode!(j.resp_body)
    assert m["created"] >= 1
    assert m["stored"] >= 1
    assert Map.has_key?(m, "throttled_total")
    assert Map.has_key?(m, "active_bans")
    # privacy: the stats payload must not contain any per-secret/per-user identifiers
    refute Map.has_key?(m, "key")
  end

  ## ── terms ────────────────────────────────────────────────────────────────

  test "GET /terms is public and renders the operator's filled-in terms (no template warning)" do
    r = conn(:get, "/terms") |> call()
    assert r.status == 200
    body = r.resp_body
    assert body =~ "Acceptable use"
    assert body =~ "Limitation of liability"
    # operator details are filled in by default (this instance), not bracketed placeholders
    assert body =~ "Impulsa SLU"
    assert body =~ "abuse@burnerpad.com"
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
