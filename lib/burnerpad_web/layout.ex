# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.Layout do
  @moduledoc """
  The shared **page chrome** — the single source of truth for every page's shell, so `Pages` supplies only
  the per-route content. This module owns:

    * the document `<head>`, including the render-blocking, SRI-pinned **theme bootstrap** (`theme.js`);
    * the in-document **icon sprite** (inline SVG `<symbol>`s, referenced by `<use>` — strict CSP keeps
      everything self-hosted, so icons are never an icon font);
    * the **site header** (brand wordmark + light/dark theme toggle), identical on every page;
    * the **footer**;
    * the SRI-pinned crypto **`<script>` tags** (`burnerpad-crypto.js` + `crypto-app.js`), emitted only on
      the crypto pages.

  Centralizing the chrome here gives it **locality**: a header/footer/script change happens in one place,
  and the invariant "every page emits the theme bootstrap + (on crypto pages) the SRI scripts, with no
  inline scripts" is verifiable here rather than re-checked in five page functions.
  """
  alias BurnerpadWeb.CryptoAssets

  @doc """
  Wrap per-route `content` in the full HTML document (sprite + header + content inside `<main>`, then the
  footer + scripts). Options:

    * `:scripts` (default `true`) — emit the two SRI-pinned crypto scripts. Set `false` for the script-light
      pages (404 / stats / terms), which still get the `<head>` theme bootstrap.
    * `:refresh` — seconds for a `<meta http-equiv="refresh">` (the stats page auto-refreshes).
  """
  def document(title, content, opts \\ []) do
    scripts = if Keyword.get(opts, :scripts, true), do: scripts(), else: ""

    refresh =
      if r = Keyword.get(opts, :refresh),
        do: ~s(\n    <meta http-equiv="refresh" content="#{r}" />),
        else: ""

    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="referrer" content="no-referrer" />#{refresh}
        <title>#{escape(title)}</title>
        <link rel="stylesheet" href="/crypto/crypto.css" />
        <!-- Render-blocking in <head> (no defer): stamps data-theme from localStorage BEFORE paint, so a
             saved light/dark choice applies with no flash. External + SRI-pinned ⇒ strict CSP, no inline. -->
        <script src="/crypto/theme.js" integrity="#{CryptoAssets.theme_sri()}" crossorigin="anonymous"></script>
      </head>
      <body>
        <main>
    #{sprite()}#{header()}#{content}    </main>
        #{footer()}#{scripts}
      </body>
    </html>
    """
  end

  @doc """
  Minimal HTML-attribute/text escaping for interpolated titles/messages. Page ids are already restricted to
  the Crockford base32 alphabet, but titles/headings/messages are escaped defensively.
  """
  def escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  ## ── chrome ──────────────────────────────────────────────────────────────

  # The site header: brand wordmark (home link) + the light/dark theme toggle. Identical on every page.
  defp header do
    """
    <header class="site-header">
      <a class="brand" href="/" aria-label="Burnerpad home">
        <svg class="brand-mark" aria-hidden="true"><use href="#i-logo"></use></svg>
        <span class="wordmark">burner<span class="ember">pad</span></span>
      </a>
      <button type="button" class="theme-toggle" data-theme-toggle aria-label="Switch light or dark theme" title="Switch theme">
        <svg class="ico i-moon" aria-hidden="true"><use href="#i-moon"></use></svg>
        <svg class="ico i-sun" aria-hidden="true"><use href="#i-sun"></use></svg>
      </button>
    </header>
    """
  end

  defp footer do
    ~s(<footer class="footer">end-to-end encrypted <span class="dot">·</span> in memory, gone on restart <span class="dot">·</span> <a href="/terms">terms</a> <span class="dot">·</span> <a href="/stats">stats</a> <span class="dot">·</span> <a class="gh" href="https://github.com/burnerpad/burnerpad-lite" target="_blank" rel="noopener noreferrer" aria-label="Source code on GitHub"><svg class="gh-mark" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z"></path></svg>source</a></footer>)
  end

  # The two SRI-pinned crypto scripts (create/reveal pages only). The leading blank line + indentation keep
  # the rendered HTML tidy when appended after the footer.
  defp scripts do
    """

        <script src="/crypto/burnerpad-crypto.js" integrity="#{CryptoAssets.bundle_sri()}" crossorigin="anonymous"></script>
        <script src="/crypto/crypto-app.js" integrity="#{CryptoAssets.app_sri()}" crossorigin="anonymous"></script>\
    """
  end

  # In-document icon sprite (referenced by <use> across the pages). Strict CSP keeps everything self-hosted,
  # so icons are inline SVG, never an icon font. The logo flame + notepad is the brand mark.
  defp sprite do
    """
    <svg class="sprite" aria-hidden="true" focusable="false">
      <symbol id="i-logo" viewBox="386.5 352.6 439.1 612.9"><g transform="translate(603.7 931.6) scale(1.05) translate(-630 -893)"><g transform="translate(451 371)"><path fill="var(--accent, #ee5a24)" d="M166.8 3.3 C168.2 0.9 168.0 2.8 168.6 3.1 C169.2 3.4 168.3 -0.9 170.3 5.2 C172.4 11.2 177.6 30.9 180.9 39.6 C184.2 48.3 187.2 52.5 190.2 57.3 C193.1 62.2 193.4 62.9 198.7 68.8 C203.9 74.7 217.0 87.0 221.8 92.7 C226.7 98.3 225.7 98.3 227.8 102.7 C229.9 107.1 232.4 113.3 234.2 119.3 C235.9 125.4 238.3 139.2 238.3 139.2 C238.3 139.2 240.4 140.0 241.3 138.8 C242.1 137.5 242.8 135.3 243.3 131.8 C243.9 128.4 244.4 122.6 244.5 118.0 C244.6 113.4 243.5 106.8 243.8 104.3 C244.1 101.8 245.1 102.7 246.4 103.1 C247.8 103.5 247.8 102.4 251.7 106.8 C255.6 111.3 264.4 121.3 269.8 129.7 C275.3 138.1 280.3 147.9 284.3 157.2 C288.4 166.4 291.4 174.6 294.2 185.3 C297.0 196.0 299.3 215.2 301.1 221.4 C302.9 227.6 302.7 222.5 305.0 222.5 C307.3 222.5 313.1 222.6 315.1 221.6 C317.1 220.6 316.6 219.6 317.2 216.7 C317.8 213.8 318.1 206.5 318.8 204.3 C319.5 202.0 320.0 202.7 321.3 203.2 C322.7 203.8 325.0 205.5 327.0 207.5 C328.9 209.6 331.5 213.0 333.1 215.4 C334.6 217.9 334.8 217.7 336.4 222.1 C337.9 226.6 341.1 236.7 342.3 242.2 C343.5 247.7 343.5 245.4 343.5 255.0 C343.5 264.6 343.9 284.6 342.4 299.9 C341.0 315.3 335.6 338.7 334.7 347.0 C333.8 355.2 333.8 348.8 337.1 349.4 C340.4 349.9 350.4 347.6 354.2 350.3 C358.1 352.9 359.0 361.0 360.2 365.3 C361.4 369.6 361.3 370.3 361.5 376.0 C361.7 381.8 361.6 394.0 361.4 399.9 C361.2 405.9 361.4 406.0 360.2 411.7 C359.0 417.3 356.3 427.3 354.2 433.7 C352.1 440.1 350.6 444.0 347.6 450.1 C344.6 456.3 340.1 464.8 336.2 470.7 C332.2 476.6 327.4 481.7 324.0 485.5 C320.6 489.2 319.8 489.9 315.7 493.2 C311.6 496.5 305.1 501.6 299.6 505.1 C294.0 508.5 288.3 511.3 282.3 513.8 C276.3 516.3 269.2 518.4 263.5 520.0 C257.7 521.6 254.1 522.4 247.8 523.3 C241.6 524.2 249.0 525.3 226.0 525.5 C203.0 525.7 131.3 524.9 110.0 524.5 C88.7 524.1 103.4 524.4 98.3 523.2 C93.2 521.9 84.9 519.3 79.4 517.1 C73.9 514.9 70.1 513.0 65.4 510.1 C60.7 507.2 56.2 504.3 51.1 499.4 C45.9 494.6 39.7 488.8 34.3 481.2 C28.9 473.6 22.9 463.6 18.8 453.7 C14.7 443.8 11.2 443.6 9.7 421.8 C8.2 400.0 10.6 345.5 9.5 323.0 C8.3 300.6 3.4 293.4 2.9 287.2 C2.3 280.9 0.7 285.8 6.0 285.5 C11.4 285.2 29.6 285.8 34.9 285.4 C40.2 285.0 36.9 286.1 37.7 283.2 C38.5 280.4 37.4 277.4 39.7 268.2 C42.0 259.0 49.2 237.0 51.3 227.8 C53.5 218.6 52.5 220.6 52.5 213.0 C52.5 205.4 51.5 187.6 51.5 182.0 C51.6 176.4 52.6 179.1 52.6 179.1 C52.6 179.1 53.7 178.0 56.9 180.6 C60.0 183.3 66.7 189.9 71.5 195.0 C76.3 200.1 82.2 206.8 85.6 210.9 C88.9 215.1 90.2 218.2 91.6 219.9 C93.0 221.6 93.3 221.1 94.0 221.1 C94.7 221.2 94.5 224.4 95.7 220.2 C96.9 216.0 99.9 207.2 101.3 195.8 C102.8 184.4 104.6 171.4 104.5 152.0 C104.4 132.6 101.2 91.7 100.8 79.3 C100.5 67.0 102.4 77.7 102.4 77.7 C102.4 77.7 102.9 77.9 106.7 81.8 C110.4 85.8 119.5 95.2 125.0 101.5 C130.5 107.9 136.7 116.6 139.6 119.9 C142.4 123.2 141.4 121.1 142.1 121.2 C142.8 121.3 142.7 125.6 143.9 120.4 C145.1 115.2 148.2 100.7 149.3 89.8 C150.4 78.9 149.8 64.0 150.6 55.1 C151.3 46.2 152.3 42.6 153.8 36.3 C155.4 30.1 157.7 22.9 159.9 17.4 C162.0 11.9 165.3 5.7 166.8 3.3Z"/></g></g><rect x="511" y="639" width="190" height="250" rx="12" fill="#fff" stroke="#1b1614" stroke-width="16"/><rect x="520" y="621" width="14" height="38" rx="7" fill="#1b1614"/><rect x="552" y="621" width="14" height="38" rx="7" fill="#1b1614"/><rect x="583" y="621" width="14" height="38" rx="7" fill="#1b1614"/><rect x="615" y="621" width="14" height="38" rx="7" fill="#1b1614"/><rect x="647" y="621" width="14" height="38" rx="7" fill="#1b1614"/><rect x="678" y="621" width="14" height="38" rx="7" fill="#1b1614"/><line x1="535" y1="724" x2="677" y2="724" stroke="#1b1614" stroke-width="10"/><line x1="535" y1="766" x2="677" y2="766" stroke="#1b1614" stroke-width="10"/><line x1="535" y1="807" x2="677" y2="807" stroke="#1b1614" stroke-width="10"/><line x1="535" y1="849" x2="677" y2="849" stroke="#1b1614" stroke-width="10"/></symbol>
      <symbol id="i-lock" viewBox="0 0 24 24"><rect x="4" y="10" width="16" height="11" rx="2.5"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></symbol>
      <symbol id="i-swap" viewBox="0 0 24 24"><path d="M4 8h13"/><path d="M14 5l3 3-3 3"/><path d="M20 16H7"/><path d="M10 13l-3 3 3 3"/></symbol>
      <symbol id="i-flame" viewBox="0 0 24 24"><path d="M12 2c1.1 3.1 3.1 4.5 4.5 6.6C17.6 10.2 18 11.9 18 13.8a6 6 0 0 1-12 0c0-1.8.8-3.4 2-4.5.1 1.2.9 2.2 2 2.6-.8-2.9.1-6 2-9.9z"/></symbol>
      <symbol id="i-refresh" viewBox="0 0 24 24"><path d="M4 12a8 8 0 0 1 13.7-5.6L20 8"/><path d="M20 3v5h-5"/><path d="M20 12a8 8 0 0 1-13.7 5.6L4 16"/><path d="M4 21v-5h5"/></symbol>
      <symbol id="i-copy" viewBox="0 0 24 24"><rect x="9" y="9" width="11" height="11" rx="2.2"/><path d="M5 15V5.5A1.5 1.5 0 0 1 6.5 4H16"/></symbol>
      <symbol id="i-check" viewBox="0 0 24 24"><path d="M5 13l4 4L19 7"/></symbol>
      <symbol id="i-warn" viewBox="0 0 24 24"><path d="M12 3.5l9 16H3z"/><path d="M12 10v4M12 17h.01"/></symbol>
      <symbol id="i-revert" viewBox="0 0 24 24"><path d="M9 14L4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H8"/></symbol>
      <symbol id="i-plus" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></symbol>
      <symbol id="i-type" viewBox="0 0 24 24"><path d="M4 7V5.5A1.5 1.5 0 0 1 5.5 4h13A1.5 1.5 0 0 1 20 5.5V7"/><path d="M9 20h6"/><path d="M12 4v16"/></symbol>
      <symbol id="i-eye" viewBox="0 0 24 24"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z"/><circle cx="12" cy="12" r="3"/></symbol>
      <symbol id="i-arrow" viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6"/></symbol>
      <symbol id="i-sun" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4.5"/><path d="M12 2v2M12 20v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M2 12h2M20 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"/></symbol>
      <symbol id="i-moon" viewBox="0 0 24 24"><path d="M20 14.5A8 8 0 0 1 9.5 4a7 7 0 1 0 10.5 10.5z"/></symbol>
    </svg>
    """
  end
end
