# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.Pages do
  @moduledoc """
  Per-route page **content** — the create page, the reveal interstitial, and the 404 / stats / terms pages.
  Each function returns its unique content and wraps it in the shared chrome (`BurnerpadWeb.Layout` —
  `<head>` + theme bootstrap, icon sprite, header, footer, and the SRI-pinned crypto scripts), so every page
  is a complete static document with **no inline scripts**. All encryption/decryption happens in the
  crypto scripts that `Layout` injects.
  """
  alias Burnerpad.Config
  alias BurnerpadWeb.Layout

  @doc "The create page."
  def home do
    body = """
    <div id="bp-intro">
    <h1 class="hero-title">Securely share one-claim secrets</h1>
    <p class="hero-sub">Encrypted in your browser before it leaves your device.</p>

    <ul class="features" aria-label="Why it's safe">
      <li class="feature">
        <svg class="ico" aria-hidden="true"><use href="#i-lock"></use></svg>
        <div><div class="feature-name">End-to-end encrypted</div><div class="feature-sub">Locked in your browser first</div></div>
      </li>
      <li class="feature">
        <svg class="ico" aria-hidden="true"><use href="#i-swap"></use></svg>
        <div><div class="feature-name">Two separate channels</div><div class="feature-sub">Link and passphrase travel apart</div></div>
      </li>
      <li class="feature">
        <svg class="ico ico-solid" aria-hidden="true"><use href="#i-flame"></use></svg>
        <div><div class="feature-name">At most one claim</div><div class="feature-sub">The server row is removed atomically</div></div>
      </li>
    </ul>
    </div>

    <form id="bp-create">
      <section class="panel">
        <div class="panel-head">
          <span class="badge">1</span>
          <span class="panel-title">Your secret</span>
          <span id="bp-create-meta" class="meta" hidden></span>
        </div>
        <textarea id="bp-input" placeholder="Paste a password, API key, or .env block…" required spellcheck="false" autocomplete="off" autocapitalize="off" autocorrect="off"></textarea>
      </section>

      <section class="panel">
        <div class="panel-head">
          <span class="badge">2</span>
          <span class="panel-title">Your passphrase</span>
          <button type="button" id="bp-pass-regen" class="regen"><svg class="ico" aria-hidden="true"><use href="#i-refresh"></use></svg>Regenerate</button>
        </div>
        <p class="hint"><strong>Send these on a separate channel</strong> from the link — it carries <strong>no key</strong>, so we can't recover them.</p>
        <div class="combo">
          <div id="bp-pass-field" class="tagfield">
            <div class="tagrow">
              <div id="bp-pass-chips" class="taglist" aria-live="polite" aria-label="Your passphrase words"></div>
              <input id="bp-pass-input" type="text" class="taginput" role="combobox" aria-autocomplete="list" aria-expanded="false" aria-controls="bp-pass-suggest" aria-label="Add a word to your passphrase" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="+ add a word" />
            </div>
          </div>
          <ul id="bp-pass-suggest" class="suggest" role="listbox" hidden></ul>
        </div>
        <div class="strengthrow"><span id="bp-pass-strength" class="strength ok">✓ 7 words · very strong</span></div>
        <p id="bp-pass-warn" class="warn warn-inline" hidden><svg class="ico" aria-hidden="true"><use href="#i-warn"></use></svg><span>Words you choose yourself are easier to guess than random ones — the <strong>generated</strong> phrase is stronger.</span></p>
      </section>

      <button type="submit" id="bp-create-btn" class="primary"><svg class="ico" aria-hidden="true"><use href="#i-lock"></use></svg><span class="btn-label">Add your secret to continue</span></button>
      <p class="trustline"><svg class="ico ico-sm" aria-hidden="true"><use href="#i-lock"></use></svg> Encrypted in your browser — we store ciphertext we can't read.</p>
      <p id="bp-error" class="error" hidden></p>
    </form>

    <section id="bp-result" hidden>
      <div id="bp-share">
        <div class="done-head">
          <span class="done-check"><svg class="ico" aria-hidden="true"><use href="#i-check"></use></svg></span>
          <div>
            <div class="done-title">Encrypted &amp; ready</div>
            <div class="done-sub">It can be claimed <strong>at most once</strong>, then it's gone — or within <strong id="bp-expiry">#{expiry_label()}</strong> if unopened. Hand it over in two parts, kept on <strong>separate channels</strong>.</div>
          </div>
        </div>

        <section class="panel">
          <div class="panel-head"><span class="badge">1</span><span class="panel-title">Send the link</span></div>
          <p class="hint">No key inside — drop it in email, Slack, a ticket.</p>
          <div class="iobox">
            <input id="bp-link" type="text" class="mono iobox-field" readonly aria-label="Your one-claim link" />
            <button id="bp-copy" type="button" class="iobox-btn"><svg class="ico" aria-hidden="true"><use href="#i-copy"></use></svg><span class="btn-label">Copy</span></button>
          </div>
        </section>

        <section class="panel">
          <div class="panel-head"><span class="badge">2</span><span class="panel-title">Share the passphrase</span></div>
          <p class="hint"><strong>On a different channel</strong> from the link — a separate app, a text, or a call.</p>
          <div class="iobox">
            <div id="bp-pass-out" class="phrase iobox-field" aria-label="Your passphrase"></div>
            <button id="bp-copy-phrase" type="button" class="iobox-btn"><svg class="ico" aria-hidden="true"><use href="#i-copy"></use></svg><span class="btn-label">Copy</span></button>
          </div>
        </section>

        <div class="burn-callout">
          <div class="burn-copy">
            <svg class="ico" aria-hidden="true"><use href="#i-revert"></use></svg>
            <span class="burn-text">
              <span class="burn-title">Sent it by mistake?</span>
              <span class="burn-sub">Remove the server's ciphertext row now — this can't be undone.</span>
            </span>
          </div>
          <button id="bp-burn" type="button" class="danger"><svg class="ico ico-solid" aria-hidden="true"><use href="#i-flame"></use></svg><span class="btn-label">Burn it now</span></button>
          <p id="bp-burn-error" class="error" hidden></p>
        </div>
      </div>

      <div id="bp-burned" class="burned" hidden>
        <svg class="burned-mark" aria-hidden="true"><use href="#i-logo"></use></svg>
        <h2>Burned</h2>
        <p>The server confirmed that its ciphertext row was removed — the link can no longer claim it.</p>
      </div>

      <div class="again-row">
        <button id="bp-again" type="button" class="link-btn"><svg class="ico" aria-hidden="true"><use href="#i-plus"></use></svg>Create another secret</button>
      </div>
    </section>
    """

    Layout.document("Burnerpad — securely share one-claim secrets", body)
  end

  @doc "The reveal interstitial for a live secret `id` (already normalized)."
  def view(id) do
    body = """
    <section id="bp-unsupported" hidden>
      <h2>This link uses an older format</h2>
      <p class="warn warn-inline"><svg class="ico" aria-hidden="true"><use href="#i-warn"></use></svg><span>This site no longer supports it. Ask the sender to create a new one — a key-less link plus a spoken passphrase.</span></p>
      <a class="cta" href="/">Create your own →</a>
    </section>

    <section id="bp-psk" hidden>
      <h2>A one-claim secret is waiting for you</h2>
      <p class="lead">Enter the passphrase you were given — the words, <strong>in order</strong>.</p>
      <div class="panel">
        <div class="panel-head">
          <span class="panel-label">Passphrase</span>
          <span id="bp-psk-count" class="count-pill"><svg class="ico" aria-hidden="true"><use href="#i-check"></use></svg><span id="bp-psk-count-n">0 / 7</span></span>
        </div>
        <div class="combo">
          <div id="bp-psk-field" class="tagfield">
            <div class="tagrow">
              <div id="bp-psk-chips" class="taglist" aria-live="polite" aria-label="Passphrase words entered"></div>
              <input id="bp-psk-input" type="text" class="taginput" role="combobox" aria-autocomplete="list" aria-expanded="false" aria-controls="bp-psk-suggest" aria-label="Type or paste the passphrase" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="type a word…" />
            </div>
          </div>
          <ul id="bp-psk-suggest" class="suggest" role="listbox" hidden></ul>
        </div>
        <p class="warn warn-inline"><svg class="ico" aria-hidden="true"><use href="#i-warn"></use></svg><span>The server removes the ciphertext <strong>before</strong> completing its reply. If the network fails, the outcome is unknown. A retry works only if the first request never claimed it, so you must confirm before trying again. After the ciphertext arrives, a wrong phrase can be retried only on this page — <strong>don't reload</strong>.</span></p>
      </div>
      <button id="bp-psk-reveal" class="primary" data-id="#{id}"><svg class="ico" aria-hidden="true"><use href="#i-type"></use></svg><span class="btn-label">Enter at least 7 words</span></button>
      <p id="bp-psk-error" class="error" hidden></p>
    </section>

    <section id="bp-revealed" hidden>
      <div class="done-head">
        <span class="done-check"><svg class="ico" aria-hidden="true"><use href="#i-check"></use></svg></span>
        <div>
          <div class="done-title">Decrypted</div>
          <div class="done-sub">Copy it now — this page holds the recovered plaintext only until you leave or reload.</div>
        </div>
      </div>
      <div class="codeblock">
        <div class="codeblock-bar">
          <span id="bp-secret-meta" class="codeblock-meta"></span>
          <button id="bp-copy-secret" type="button" class="copy-secret"><svg class="ico" aria-hidden="true"><use href="#i-copy"></use></svg><span class="btn-label">Copy</span></button>
        </div>
        <div class="codeblock-body">
          <pre id="bp-secret" translate="no" class="notranslate"></pre>
          <div id="bp-secret-fade" class="codeblock-fade" aria-hidden="true"></div>
        </div>
      </div>
      <div class="again-row">
        <a class="link-btn" href="/">Send your own secret<svg class="ico" aria-hidden="true"><use href="#i-arrow"></use></svg></a>
      </div>
    </section>
    """

    Layout.document("A secret was shared with you · Burnerpad", body)
  end

  @doc """
  The 404 / not-found page — served for a gone, expired, OR unknown id (the same page for all three; a live
  id still necessarily returns 200). `heading` + `message` are the two lines under the big "404". No crypto scripts.
  """
  def status(heading, message) do
    body = """
    <section class="notfound">
      <div class="notfound-code">404</div>
      <h2>#{Layout.escape(heading)}</h2>
      <p class="notfound-msg">#{Layout.escape(message)}</p>
      <a class="link-btn" href="/">Send your own secret<svg class="ico" aria-hidden="true"><use href="#i-arrow"></use></svg></a>
    </section>
    """

    Layout.document("Not found · Burnerpad", body, scripts: false)
  end

  @doc "Public aggregate transparency page. No scripts and no visitor-level data."
  def stats(m) do
    today = List.last(m.daily_visits)
    today_visits = Map.fetch!(today, :visits)
    today_created = Map.fetch!(today, :secrets_created)

    body = """
    <h2 class="page-title">Transparency</h2>
    <p class="lead">Aggregate counts only — no contents, IDs, or IPs. Everything lives in RAM and resets on restart.</p>
    <div class="stats">
      #{stat(m.resident, "resident ciphertexts", "c-accent")}
      #{stat(today_visits, "homepage visits today", "c-accent")}
      #{stat(today_created, "secrets created today", "c-good")}
      #{stat(m.created, "created since restart", "c-text")}
      #{stat(m.revealed, "read", "c-good")}
      #{stat(m.burned, "revoked", "c-text")}
      #{stat(m.expired, "expired", "c-muted")}
      #{stat(m.throttled_total, "requests throttled", "c-text")}
      #{stat(m.banned_total, "bans issued", "c-warn")}
      #{stat(m.active_bans, "sources blocked now", "c-danger")}
    </div>
    <h2 id="activity-chart-title" class="page-title stats-section-title">Daily activity</h2>
    <p class="lead">Homepage requests and successful secret creations, counted only as daily totals. No contents, IDs, IPs, cookies, or visitor identifiers are retained.</p>
    <section class="activity-chart" aria-labelledby="activity-chart-title">
      <div class="activity-legend" aria-hidden="true">
        <span><span class="chart-swatch chart-swatch-visits"></span>Homepage visits</span>
        <span><span class="chart-swatch chart-swatch-created"></span>Secrets created</span>
      </div>
      #{activity_chart(m.daily_visits)}
      #{activity_table(m.daily_visits)}
    </section>
    <div class="stats-meta">
      <div>Version <span class="mono">#{Layout.escape(m.version)}</span></div>
      <div>Resident capacity <span class="mono">#{commas(m.resident)} / #{commas(m.capacity)}</span></div>
      <div>Uptime <span class="mono">#{uptime(m.uptime_seconds)}</span></div>
      <div><a href="/api/stats">JSON</a></div>
    </div>
    <div class="again-row">
      <a class="link-btn" href="/"><svg class="ico" aria-hidden="true"><use href="#i-plus"></use></svg>Create another secret</a>
    </div>
    """

    Layout.document("Stats · Burnerpad", body, scripts: false, refresh: 30)
  end

  # One transparency stat card; `color` is a `c-*` class that tints the number (the design's palette).
  defp stat(n, label, color) do
    ~s(<div class="stat"><span class="num #{color}">#{commas(n)}</span><span class="lbl">#{label}</span></div>)
  end

  defp activity_chart(days) do
    max_count =
      days
      |> Enum.flat_map(&[&1.visits, &1.secrets_created])
      |> Enum.max(fn -> 0 end)

    {tick_step, axis_max} = chart_axis(max_count)
    chart_width = 320
    chart_height = 220
    plot_left = 40
    plot_right = 312
    plot_top = 12
    plot_bottom = 184
    plot_height = plot_bottom - plot_top
    group_width = (plot_right - plot_left) / length(days)

    grid =
      Enum.map_join(0..div(axis_max, tick_step), "\n", fn tick ->
        value = tick * tick_step
        y = plot_bottom - round(value * plot_height / axis_max)

        """
        <line class="chart-grid" x1="#{plot_left}" y1="#{y}" x2="#{plot_right}" y2="#{y}" />
        <text class="chart-axis-label" x="#{plot_left - 5}" y="#{y + 3}" text-anchor="end">#{commas(value)}</text>
        """
      end)

    bars =
      days
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {%{date: date, visits: visits, secrets_created: created}, index} ->
        center = plot_left + group_width * (index + 0.5)

        [
          chart_bar(
            center - 7,
            visits,
            axis_max,
            plot_top,
            plot_bottom,
            plot_height,
            "visits",
            date
          ),
          chart_bar(
            center + 1,
            created,
            axis_max,
            plot_top,
            plot_bottom,
            plot_height,
            "created",
            date
          )
        ]
        |> Enum.join("\n")
      end)

    last_index = length(days) - 1

    labels =
      days
      |> Enum.with_index()
      |> Enum.filter(fn {_day, index} ->
        (rem(index, 2) == 0 and index != last_index - 1) or index == last_index
      end)
      |> Enum.map_join("\n", fn {%{date: date}, index} ->
        center = plot_left + group_width * (index + 0.5)
        short_date = date |> String.slice(5, 5) |> String.replace("-", "/")

        ~s(<text class="chart-date" x="#{chart_number(center)}" y="202" text-anchor="middle">#{Layout.escape(short_date)}</text>)
      end)

    """
    <svg class="activity-plot" viewBox="0 0 #{chart_width} #{chart_height}" role="img" aria-labelledby="activity-svg-title activity-svg-desc">
      <title id="activity-svg-title">Daily homepage visits and secrets created</title>
      <desc id="activity-svg-desc">Grouped bar chart for the last 14 UTC days. Orange bars are homepage visits and green bars are successfully created secrets. Exact values are available in the accompanying table.</desc>
      #{grid}
      <line class="chart-axis" x1="#{plot_left}" y1="#{plot_top}" x2="#{plot_left}" y2="#{plot_bottom}" />
      #{bars}
      #{labels}
    </svg>
    """
  end

  defp chart_bar(x, count, axis_max, plot_top, plot_bottom, plot_height, series, date) do
    height = if count == 0, do: 0, else: max(round(count * plot_height / axis_max), 1)
    y = max(plot_bottom - height, plot_top)

    label =
      case series do
        "visits" -> "#{commas(count)} homepage visits on #{date}"
        "created" -> "#{commas(count)} secrets created on #{date}"
      end

    """
    <rect class="chart-bar chart-bar-#{series}" x="#{chart_number(x)}" y="#{y}" width="6" height="#{height}" rx="1">
      <title>#{Layout.escape(label)}</title>
    </rect>
    """
  end

  defp activity_table(days) do
    rows =
      Enum.map_join(days, "\n", fn %{date: date, visits: visits, secrets_created: created} ->
        """
        <tr>
          <th scope="row">#{Layout.escape(date)}</th>
          <td>#{visits}</td>
          <td>#{created}</td>
        </tr>
        """
      end)

    """
    <div class="sr-only">
      <table>
        <caption>Daily homepage visits and successfully created secrets</caption>
        <thead><tr><th scope="col">UTC date</th><th scope="col">Homepage visits</th><th scope="col">Secrets created</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </div>
    """
  end

  defp chart_axis(max_count) do
    rough_step = max(div(max_count + 4, 5), 1)
    magnitude = chart_magnitude(rough_step)
    normalized = rough_step / magnitude

    multiplier =
      cond do
        normalized <= 1 -> 1
        normalized <= 2 -> 2
        normalized <= 5 -> 5
        true -> 10
      end

    step = multiplier * magnitude
    axis_max = if max_count <= 4, do: 4, else: div(max_count + step - 1, step) * step
    {step, axis_max}
  end

  defp chart_magnitude(n), do: chart_magnitude(n, 1)
  defp chart_magnitude(n, magnitude) when n < 10, do: magnitude
  defp chart_magnitude(n, magnitude), do: chart_magnitude(div(n, 10), magnitude * 10)

  defp chart_number(number) when is_integer(number), do: Integer.to_string(number)
  defp chart_number(number), do: number |> Float.round(1) |> Float.to_string()

  # 12345 -> "12,345"
  defp commas(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp uptime(s) when s < 60, do: "#{s}s"
  defp uptime(s) when s < 3600, do: "#{div(s, 60)}m"
  defp uptime(s) when s < 86_400, do: "#{div(s, 3600)}h #{rem(div(s, 60), 60)}m"
  defp uptime(s), do: "#{div(s, 86_400)}d #{rem(div(s, 3600), 24)}h"

  defp expiry_label do
    seconds = Config.get(:ttl_seconds)

    cond do
      rem(seconds, 3600) == 0 -> "#{div(seconds, 3600)}h"
      rem(seconds, 60) == 0 -> "#{div(seconds, 60)}m"
      true -> "#{seconds}s"
    end
  end

  @doc "Public Terms & Acceptable-Use page — a TEMPLATE rendered with operator placeholders from config."
  def terms do
    op = Layout.escape(Config.operator_name())
    email = Layout.escape(Config.abuse_email())
    juris = Layout.escape(Config.jurisdiction())

    body = """
    <h2 class="page-title">Terms &amp; acceptable use</h2>
    <p class="terms-sub">Operated by #{op} · #{juris}</p>

    <div class="terms-card">
      <div class="terms-item">
        <h3 class="terms-h">1. What this is</h3>
        <p class="terms-b">A free, no-accounts, end-to-end-encrypted one-time secret sharing service operated by #{op}. In the unmodified official client, your secret is encrypted before upload and the server stores only opaque ciphertext. The passphrase is shared separately and the link carries no key. The normal service therefore <strong>does not receive and cannot read, scan, index, or proactively moderate</strong> your plaintext. As with any website, compromise of the live site or your device can replace or observe client code.</p>
      </div>
      <div class="terms-item">
        <h3 class="terms-h">2. No warranty</h3>
        <p class="terms-b">The service is provided "as is" and "as available", without warranty of any kind — express, implied, or statutory — including merchantability, fitness for a particular purpose, security, accuracy, or non-infringement. We do not warrant that it will be uninterrupted, secure, or error-free, or that the encryption is unbreakable.</p>
      </div>
      <div class="terms-item">
        <h3 class="terms-h">3. Limitation of liability</h3>
        <p class="terms-b">To the fullest extent permitted by law, #{op} is not liable for any indirect, incidental, special, consequential, or exemplary damages, or for loss of data — including a secret that is leaked, read by the wrong person, lost, expired, or unrecoverable. The service is free; our aggregate liability is limited to what you paid for it (nothing).</p>
      </div>
      <div class="terms-item">
        <h3 class="terms-h">4. Ephemeral — not storage</h3>
        <p class="terms-b">Ciphertext rows are held in application memory, atomically removed on the first claim, removed at expiry, and all lost when the service restarts or deploys. Removal happens before the claim response is delivered, so even the first claimant may receive nothing after a network failure. This is not storage or backup; we do not guarantee retention, delivery, or recovery.</p>
      </div>
      <div class="terms-item">
        <h3 class="terms-h">5. Acceptable use</h3>
        <p class="terms-b">You agree not to use the service to create, share, or link to:</p>
        <ul>
          <li>unlawful content, or anything that facilitates illegal activity;</li>
          <li>child sexual abuse material, or non-consensual intimate imagery;</li>
          <li>malware, ransomware, exploits, or phishing;</li>
          <li>spam, bulk or automated abuse, or attempts to evade rate limits;</li>
          <li>another person's private or financial data, stolen credentials, or leaked databases;</li>
          <li>harassment, threats, or incitement of violence;</li>
          <li>material that infringes copyright, trademark, or other rights;</li>
          <li>impersonation, or anything that attacks, overloads, or probes the service.</li>
        </ul>
      </div>
      <div class="terms-item">
        <h3 class="terms-h">6. Your content is your responsibility</h3>
        <p class="terms-b">You are solely responsible for what you share and for any consequences of it. We do not endorse, monitor, or guarantee user content and are not responsible for it.</p>
      </div>
      <div class="terms-item">
        <h3 class="terms-h">7. Reporting &amp; removal</h3>
        <p class="terms-b">Because we cannot read content, moderation is reactive. To report abuse or illegal material, email <a href="mailto:#{email}">#{email}</a> with: (a) the secret's exact link or ID; (b) a clear explanation of why it is illegal or breaches the acceptable-use list above; (c) your name and a contact email; and (d) a statement that your report is accurate and made in good faith. We may remove (purge) a reported secret by its ID. We cannot retrieve or disclose content we are unable to decrypt. Reports may contain contact details; we retain them only while needed to investigate or meet a legal obligation, then delete them.</p>
      </div>
      <div class="terms-item">
        <h3 class="terms-h">8. Abuse controls &amp; service refusal</h3>
        <p class="terms-b">We may refuse service or reject requests without notice, including for suspected abuse. The application uses per-network-source request limits, row and byte quotas, escalating temporary bans, and global request and creation ceilings. These controls do not identify an individual or guarantee permanent exclusion. People behind a shared NAT/CGNAT may be limited together, while distributed actors can use many sources and may still exhaust global capacity. Because we keep no source-to-secret mapping, limiting a source does not locate or remove secrets already accepted. A reported secret can be purged only when its exact link or ID is supplied; otherwise accepted rows leave through claim, expiry, restart, or deployment. Legitimate high-frequency or automated use should set a short <code>ttl</code> so its budget recycles quickly.</p>
      </div>
      <div class="terms-item">
        <h3 class="terms-h">9. Privacy</h3>
        <p class="terms-b">We require no account. The application processes client IP addresses only to apply rate limiting and abuse controls; our lawful basis is our legitimate interest in keeping the service available and preventing abuse (GDPR / Andorra Qualified Law 29/2021, Art. 6(1)(f)). Before any application counter is stored, each IP prefix is replaced with a purpose-separated keyed token whose random key exists only in RAM. Rate tokens are retained for at most about three minutes, ban/strike tokens for about 48 hours, and volume-budget tokens for at most the configured secret TTL plus about 16 minutes. The application keeps no source-to-secret mapping. Operational request events retain only an allowlisted route class, method, response status, duration, and release; they exclude secret IDs, management tokens, ciphertext, phrases, bodies, full request paths, raw IP addresses, pseudonymous source tokens, and source-IP mappings. The public stats page counts homepage requests and successful secret creations per UTC day in memory; it sets no analytics cookie and retains no IP, fingerprint, secret ID, or other visitor- or secret-level analytics record. Homepage figures are request counts, not unique people. The root-only host diagnostic retains hourly aggregate service/resource samples for about 13 months; container event logs are size-bounded. These records contain none of the excluded capability or source fields above. The data controller is #{op} (#{juris}); for privacy questions or to exercise your rights (access, erasure, objection) email <a href="mailto:#{email}">#{email}</a>, and you may lodge a complaint with your data-protection supervisory authority (in Andorra, the APDA). We use Cloudflare to deliver and protect the service; it processes connection data (including your IP and requested URL) as our processor, and the operator must configure the shortest suitable Cloudflare retention. The service is therefore not "zero-log".</p>
      </div>
      <div class="terms-item">
        <h3 class="terms-h">10. Changes &amp; governing law</h3>
        <p class="terms-b">We may update these terms; continued use means you accept the changes. These terms are governed by the laws of #{juris}. Contact: #{op} — <a href="mailto:#{email}">#{email}</a>.</p>
      </div>
      <p class="terms-abuse">Reports &amp; abuse: <a href="mailto:#{email}">#{email}</a></p>
    </div>
    """

    Layout.document("Terms · Burnerpad", body, scripts: false)
  end
end
