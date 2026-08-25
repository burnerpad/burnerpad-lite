// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

const cloudflareTransformation = /rocket-loader|cdn-cgi\/scripts|data-cfasync/i;

export const hasUnsafeHtmlTransformation = (html) => {
  if (typeof html !== "string" || cloudflareTransformation.test(html)) return true;

  const openTag = /<script\b([^>]*)>/gi;
  const closeTag = /<\/script\s*>/gi;
  let open;

  while ((open = openTag.exec(html)) !== null) {
    const src = open[1].match(/\bsrc\s*=\s*(["'])(.*?)\1/i)?.[2] || "";
    if (!src.startsWith("/crypto/")) return true;

    closeTag.lastIndex = openTag.lastIndex;
    const close = closeTag.exec(html);
    if (close === null || /\S/.test(html.slice(openTag.lastIndex, close.index))) return true;

    openTag.lastIndex = closeTag.lastIndex;
  }

  return false;
};
