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
    <h1 class="hero-title">Securely share one-read secrets</h1>
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
        <div><div class="feature-name">One read, then gone</div><div class="feature-sub">Self-destructs, nothing on disk</div></div>
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
        <textarea id="bp-input" placeholder="Paste a password, API key, or .env block…" required></textarea>
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
            <div class="done-sub">It opens <strong>once</strong>, then it's gone — or in <strong>24h</strong> if unopened. Hand it over in two parts, kept on <strong>separate channels</strong>.</div>
          </div>
        </div>

        <section class="panel">
          <div class="panel-head"><span class="badge">1</span><span class="panel-title">Send the link</span></div>
          <p class="hint">No key inside — drop it in email, Slack, a ticket.</p>
          <div class="iobox">
            <input id="bp-link" type="text" class="mono iobox-field" readonly aria-label="Your one-time link" />
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
              <span class="burn-sub">Destroy it now, before it's opened — this can't be undone.</span>
            </span>
          </div>
          <button id="bp-burn" type="button" class="danger"><svg class="ico ico-solid" aria-hidden="true"><use href="#i-flame"></use></svg><span class="btn-label">Burn it now</span></button>
        </div>
      </div>

      <div id="bp-burned" class="burned" hidden>
        <svg class="burned-mark" aria-hidden="true"><use href="#i-logo"></use></svg>
        <h2>Burned</h2>
        <p>This secret has been destroyed — the link no longer works.</p>
      </div>

      <div class="again-row">
        <button id="bp-again" type="button" class="link-btn"><svg class="ico" aria-hidden="true"><use href="#i-plus"></use></svg>Create another secret</button>
      </div>
    </section>
    """

    Layout.document("Burnerpad — securely share one-read secrets", body)
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
      <h2>A one-time secret is waiting for you</h2>
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
        <p class="warn warn-inline"><svg class="ico" aria-hidden="true"><use href="#i-warn"></use></svg><span>You can open this <strong>once</strong> — revealing destroys it on the server. If the phrase is wrong you can retry here, but <strong>don't reload</strong> afterward: this page then holds the only copy.</span></p>
      </div>
      <button id="bp-psk-reveal" class="primary" data-id="#{id}"><svg class="ico" aria-hidden="true"><use href="#i-type"></use></svg><span class="btn-label">Enter at least 7 words</span></button>
      <p id="bp-psk-error" class="error" hidden></p>
    </section>

    <section id="bp-revealed" hidden>
      <div class="done-head">
        <span class="done-check"><svg class="ico" aria-hidden="true"><use href="#i-check"></use></svg></span>
        <div>
          <div class="done-title">Decrypted</div>
          <div class="done-sub">Copy it now — you won't see it again.</div>
        </div>
      </div>
      <div class="codeblock">
        <div class="codeblock-bar">
          <span id="bp-secret-meta" class="codeblock-meta"></span>
          <button id="bp-copy-secret" type="button" class="copy-secret"><svg class="ico" aria-hidden="true"><use href="#i-copy"></use></svg><span class="btn-label">Copy</span></button>
        </div>
        <div class="codeblock-body">
          <pre id="bp-secret"></pre>
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
  The 404 / not-found page — served for a gone, expired, OR unknown id (no existence oracle: the same page
  for all three). `heading` + `message` are the two lines under the big "404". No crypto scripts.
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

  @doc "Public, aggregate transparency page. No scripts; numbers only (nothing about any secret)."
  def stats(m) do
    body = """
    <h2 class="page-title">Transparency</h2>
    <p class="lead">Aggregate counts only — no contents, IDs, or IPs. Everything lives in RAM and resets on restart.</p>
    <div class="stats">
      #{stat(m.stored, "live secrets", "c-accent")}
      #{stat(m.created, "created", "c-text")}
      #{stat(m.revealed, "read", "c-good")}
      #{stat(m.burned, "revoked", "c-text")}
      #{stat(m.expired, "expired", "c-muted")}
      #{stat(m.throttled_total, "requests throttled", "c-text")}
      #{stat(m.banned_total, "bans issued", "c-warn")}
      #{stat(m.active_bans, "sources blocked now", "c-danger")}
    </div>
    <div class="stats-meta">
      <div>Capacity <span class="mono">#{commas(m.stored)} / #{commas(m.capacity)}</span></div>
      <div>Uptime <span class="mono">#{uptime(m.uptime_seconds)}</span></div>
      <div><a href="/stats.json">JSON</a></div>
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
        <p class="terms-b">A free, anonymous, no-accounts, end-to-end-encrypted one-time secret sharing service operated by #{op}. Your secret is encrypted in your browser; we store only opaque ciphertext. The decryption key never reaches our server — it stays in your browser and is rebuilt from a passphrase you share on a separate channel, and the link itself carries no key. We therefore <strong>cannot read, decrypt, scan, verify, index, or proactively moderate</strong> what you share.</p>
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
        <p class="terms-b">Secrets are held in memory only, self-destruct on first read or when their timer expires, and are lost if the service restarts. This is not storage or backup; we do not guarantee retention, delivery, or recovery. Once a secret is gone, it cannot be recovered.</p>
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
        <p class="terms-b">Because we cannot read content, moderation is reactive. To report abuse or illegal material, send the secret's link or ID to <a href="mailto:#{email}">#{email}</a>. We may remove (purge) a reported secret by its ID. We cannot retrieve or disclose content we are unable to decrypt.</p>
      </div>
      <div class="terms-item">
        <h3 class="terms-h">8. Suspension, banning &amp; rate limiting</h3>
        <p class="terms-b">We may, at our discretion and without notice, rate-limit, block, suspend, or permanently ban any user or IP address, or refuse service, for any reason — including suspected abuse.</p>
      </div>
      <div class="terms-item">
        <h3 class="terms-h">9. Privacy</h3>
        <p class="terms-b">We require no account and cannot read your secrets, keys, or passphrases. We do process client IP addresses to apply rate limiting and abuse controls, and we log abuse reports — so the service is not "zero-log".</p>
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
