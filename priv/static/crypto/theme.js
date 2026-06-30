// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

// Theme bootstrap + toggle — the ONLY theme logic on the site. Loaded as an external, SRI-pinned script
// in <head> with NO defer/async, so it runs render-blocking BEFORE first paint: it reads the saved choice
// and stamps `data-theme` on <html> before the body is drawn, so there is no flash of the wrong theme.
//
// Persistence is `localStorage` (key `bp_theme`), NOT a cookie: it never leaves the browser, never reaches
// the server, and so keeps the site sessionless/cookie-free. The default (no stored choice) is dark, set by
// the `:root` palette in crypto.css; this script only writes an attribute when the user has explicitly
// chosen. Colors live entirely in CSS (`:root[data-theme="light"]`), and so do the toggle icons — this
// script just flips the attribute, so it works on every page including the script-less status pages.
(function () {
  "use strict";
  var KEY = "bp_theme";

  // ── runs immediately, before paint ──
  try {
    var saved = localStorage.getItem(KEY);
    if (saved === "light" || saved === "dark") {
      document.documentElement.setAttribute("data-theme", saved);
    }
  } catch (e) {
    /* private mode / storage disabled: fall back to the CSS default (dark) */
  }

  function current() {
    return document.documentElement.getAttribute("data-theme") === "light" ? "light" : "dark";
  }

  function apply(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    try {
      localStorage.setItem(KEY, theme);
    } catch (e) {
      /* choice still applies for this page view even if it can't be persisted */
    }
  }

  // ── wire the toggle once the DOM exists ──
  function wire() {
    var btns = document.querySelectorAll("[data-theme-toggle]");
    for (var i = 0; i < btns.length; i++) {
      btns[i].addEventListener("click", function () {
        apply(current() === "dark" ? "light" : "dark");
      });
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", wire);
  } else {
    wire();
  }
})();
