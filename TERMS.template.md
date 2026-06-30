# Terms of Use & Acceptable Use — TEMPLATE

> ⚠️ **This is a template, not legal advice.** It covers the *operator* of a public instance — the
> software itself is just licensed code (see `LICENSE`). If you run a public instance, **have a lawyer
> review and adapt this for your jurisdiction**, then fill in the placeholders.
>
> **You don't need to edit this file to run the site.** The live `/terms` page is rendered by the app and
> reads three environment variables — set them and the placeholders fill in automatically:
>
> | Variable | Fills | Example |
> |---|---|---|
> | `OPERATOR_NAME` | `[operator name]` | `Acme Inc.` |
> | `ABUSE_EMAIL` | `[abuse@your-domain]` | `abuse@example.com` |
> | `JURISDICTION` | `[your jurisdiction]` | `England & Wales` |
>
> Keep this Markdown copy in sync with the rendered page if you change the wording, and review the
> **legal notes** at the bottom before going live.

---

## 1. What this is

A free, anonymous, no-accounts, end-to-end-encrypted one-time secret sharing service operated by
**[operator name]**. Your secret is encrypted in your browser; we store only opaque ciphertext. The
decryption key never reaches our server — it stays in your browser and is rebuilt from a passphrase you
share on a separate channel, and the link itself carries no key. We therefore **cannot read, decrypt,
scan, verify, index, or proactively moderate** what you share.

## 2. No warranty

The service is provided "as is" and "as available", without warranty of any kind — express, implied, or
statutory — including merchantability, fitness for a particular purpose, security, accuracy, or
non-infringement. We do not warrant that it will be uninterrupted, secure, or error-free, or that the
encryption is unbreakable.

## 3. Limitation of liability

To the fullest extent permitted by law, **[operator name]** is not liable for any indirect, incidental,
special, consequential, or exemplary damages, or for loss of data — including a secret that is leaked,
read by the wrong person, lost, expired, or unrecoverable. The service is free; our aggregate liability is
limited to what you paid for it (nothing).

## 4. Ephemeral — not storage

Secrets are held in memory only, self-destruct on first read or when their timer expires, and are lost if
the service restarts. This is not storage or backup; we do not guarantee retention, delivery, or recovery.
Once a secret is gone, it cannot be recovered.

## 5. Acceptable use

You agree not to use the service to create, share, or link to:

- unlawful content, or anything that facilitates illegal activity;
- child sexual abuse material, or non-consensual intimate imagery;
- malware, ransomware, exploits, or phishing;
- spam, bulk or automated abuse, or attempts to evade rate limits;
- another person's private or financial data, stolen credentials, or leaked databases;
- harassment, threats, or incitement of violence;
- material that infringes copyright, trademark, or other rights;
- impersonation, or anything that attacks, overloads, or probes the service.

## 6. Your content is your responsibility

You are solely responsible for what you share and for any consequences of it. We do not endorse, monitor,
or guarantee user content and are not responsible for it.

## 7. Reporting & removal

Because we cannot read content, moderation is reactive. To report abuse or illegal material, send the
secret's link or ID to **[abuse@your-domain]**. We may remove (purge) a reported secret by its ID. We
cannot retrieve or disclose content we are unable to decrypt.

## 8. Suspension, banning & rate limiting

We may, at our discretion and without notice, rate-limit, block, suspend, or permanently ban any user or
IP address, or refuse service, for any reason — including suspected abuse.

## 9. Privacy

We require no account and cannot read your secrets, keys, or passphrases. We do process client IP
addresses to apply rate limiting and abuse controls, and we log abuse reports — so the service is not
"zero-log".

## 10. Changes & governing law

We may update these terms; continued use means you accept the changes. These terms are governed by the
laws of **[your jurisdiction]**. Contact: **[operator name]** — **[abuse@your-domain]**.

---

## Legal notes for the operator (delete before publishing)

- **Not legal advice.** Have a lawyer review for your jurisdiction. The enforceability of "as-is"
  disclaimers and the liability cap varies and may be limited against consumers / under EU law.
- **Privacy law.** You process client IPs for rate limiting; an IP is personal data under GDPR/UK-GDPR.
  Consider a short Privacy Policy and a lawful basis. Don't claim "zero-log" or "fully anonymous".
- **Don't overstate the crypto.** Avoid "unbreakable" / "military-grade". The envelope uses AES-256-GCM
  (link mode) and PBKDF2-HMAC-SHA256 + AES-256-GCM (passphrase mode); state it without a guarantee.
- **DMCA (US).** To rely on the DMCA §512 safe harbor you must register a designated agent with the U.S.
  Copyright Office (online, ~$6, re-file every ~3 years) and follow notice-and-takedown.
- **Section 230 (US only)** generally immunizes you for third-party content and good-faith removal, but has
  carve-outs (federal crime, IP, FOSTA, the 2025 TAKE IT DOWN Act's 48-hour NCII removal duty) and does
  not protect a non-US operator.
- **Removal is by ID.** The in-app `POST /s/:id/report` is non-destructive (it only logs/flags, so a
  stranger who has the URL can't delete an in-flight secret); actual takedown is an operator action that
  purges by ID.
