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

A free, no-accounts, end-to-end-encrypted one-time secret sharing service operated by
**[operator name]**. In the unmodified official client, your secret is encrypted before upload and the
server stores only opaque ciphertext. The passphrase is shared separately and the link carries no key.
The normal service therefore **does not receive and cannot read, scan, index, or proactively moderate**
your plaintext. As with any website, compromise of the live site or your device can replace or observe
client code.

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

Ciphertext rows are held in application memory, atomically removed on the first claim, removed at expiry,
and all lost when the service restarts or deploys. Removal happens before the claim response is delivered,
so even the first claimant may receive nothing after a network failure. This is not storage or backup; we
do not guarantee retention, delivery, or recovery.

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

Because we cannot read content, moderation is reactive. To report abuse or illegal material, email
**[abuse@your-domain]** with: (a) the secret's exact link or ID; (b) a clear explanation of why it is
illegal or breaches the acceptable-use list above; (c) your name and a contact email; and (d) a statement
that your report is accurate and made in good faith. We may remove (purge) a reported secret by its ID. We
cannot retrieve or disclose content we are unable to decrypt.

## 8. Abuse controls & service refusal

We may refuse service or reject requests without notice, including for suspected abuse. The application
uses per-network-source request limits, row and byte quotas, escalating temporary bans, and global request
and creation ceilings. These controls do not identify an individual or guarantee permanent exclusion.
People behind a shared NAT/CGNAT may be limited together, while distributed actors can use many sources and may
still exhaust global capacity. Because we keep no source-to-secret mapping, limiting a source does not
locate or remove secrets already accepted. A reported secret can be purged only when its exact link or ID
is supplied; otherwise accepted rows leave through claim, expiry, restart, or deployment. Legitimate
high-frequency or automated use should set a short `ttl` so its budget recycles quickly.

## 9. Privacy

We require no account. The application processes client IP addresses only to apply rate limiting and abuse
controls; our lawful basis is
our legitimate interest in keeping the service available and preventing abuse (GDPR / your local
data-protection law, Art. 6(1)(f) or equivalent). Before any abuse counter is stored, the IP prefix is
replaced with a purpose-separated keyed token whose random key exists only in RAM. Rate tokens are retained
for at most about three minutes, ban/strike tokens for about 48 hours, and volume-budget tokens for at
most the configured secret TTL plus about 16 minutes. The application keeps no source-to-secret mapping.
Operational request events retain only an allowlisted route class, method, response status, duration, and
release; they exclude secret IDs, management tokens, ciphertext, phrases, bodies, full request paths, raw
IP addresses, pseudonymous source tokens, and source-IP mappings. The data controller is **[operator name]** (**[your
jurisdiction]**); for privacy questions or to exercise your rights (access, erasure, objection) contact
**[abuse@your-domain]**, and you may lodge a complaint with your data-protection supervisory authority. If
you put a CDN/edge provider (e.g. Cloudflare) in front, it processes connection data (including the client
IP and requested URL)
as your processor — name it here and configure the shortest suitable retention. Abuse reports arrive by
email and may contain reporter contact details; retain them only while needed for investigation or a legal
obligation, then delete them. The public stats page may count homepage requests and successful secret
creations per UTC day in memory; it does not set a visitor cookie or retain an IP, fingerprint, secret ID,
or other visitor- or secret-level analytics record. Homepage figures do not claim to count unique people.
The root-only host diagnostic retains hourly aggregate service/resource samples for up to 12 months;
container event logs are size-bounded. These records contain none of the excluded capability or source
fields above. The service is therefore not "zero-log".

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
- **Anonymous abuse controls.** Do not describe network-source controls as account/user suspension or
  permanent individual exclusion. State the shared NAT/CGNAT collateral, distributed-source limits, and
  exact-ID-only purge behavior.
- **DMCA (US).** To rely on the DMCA §512 safe harbor you must register a designated agent with the U.S.
  Copyright Office (online, ~$6, re-file every ~3 years) and follow notice-and-takedown.
- **Section 230 (US only)** generally immunizes you for third-party content and good-faith removal, but has
  carve-outs (federal crime, IP, FOSTA, the 2025 TAKE IT DOWN Act's 48-hour NCII removal duty) and does
  not protect a non-US operator.
- **Removal is by ID.** Notices arrive through the abuse contact above; actual takedown is an operator
  action that purges by ID. Keep full-path/source HTTP logging disabled; retain only the sanitized
  operational fields described above.
