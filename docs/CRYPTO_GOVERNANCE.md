# Cryptographic governance

Burnerpad is solo-maintained, but its protocol is not allowed to drift by convenience. This policy applies
to the parent web client and the independent `@burnerpad/crypto` repository.

## Frozen construction

Official protocol creation is frozen at suite `0x02`. Existing suite IDs, byte layouts, KDF parameters,
AAD, reject reasons, and vectors are immutable. A compatibility fix may harden type validation, memory
hygiene, error handling, tests, tooling, or documentation without changing derived/encrypted bytes.

A new suite, KDF, AEAD, key schedule, AAD layout, external record binding, receiver identity feature, or
key-commitment construction requires all of the following before code is merged:

1. a written threat model and ADR explaining the concrete requirement and why existing suites are kept;
2. an independent cryptography expert's review of the construction and implementation;
3. an append-only suite ID and normative specification, never reinterpretation of `0x01` or `0x02`;
4. independent reference implementations/backends and frozen cross-language known-answer vectors;
5. downgrade, confusion, substitution, malformed-input, randomness, and interoperability tests;
6. a migration/compatibility plan that keeps old vectors green and old ciphertext readable;
7. a signed release with checksums, SBOM, provenance, and public review artifacts.

AI review, general application-security review, and passing tests are useful but do not substitute for the
independent cryptographic expert.

## Accepted properties that must remain documented

- Reveal is an at-most-once server claim, not exactly-once delivery or decryption.
- Suite `0x02` does not bind an external server record. Reusing a phrase permits valid record substitution;
  official clients generate a unique phrase per secret.
- AES-GCM is not treated as a key-committing proof against malicious-sender equivocation.
- A live browser origin controls HTML and expected SRI hashes. SRI detects asset drift only while the HTML
  trust root remains intact; the independently signed CLI narrows this threat.
- The server may copy ciphertext, deny service, or destructively claim by ID. End-to-end encryption does
  not prove server deletion or availability.

## Change and release discipline

- Use signed, DCO-signoff commits and signed immutable tags; prohibit force pushes and tag movement.
- Every change runs vector reproducibility, two-backend self-test, bundle conformance, adversarial/property,
  randomness, record-swap, packaging, and CLI tests.
- Keep the browser bundle zero-dependency and no-build. Its audited source bytes are its runtime bytes.
- Review changes in `SPEC.md`, vectors, the shipping bundle, reference implementation, and changelog as one
  atomic protocol unit.
- The parent updates only to a reviewed, signed, immutable nested release tag and regenerates committed
  SRI explicitly.
- Parent CI verifies that the gitlink exactly matches the nested package-version tag and validates that
  annotated tag against the parent-owned release-signer trust file before testing or publishing it.
- Security claims in README, context, architecture, terms, UI, CLI, and security policy change together.

Because there is no second maintainer, required CI, signed history, immutable artifacts, public provenance,
an empty routine-bypass list, and independent expert review are the compensating controls. If the founder
cannot obtain expert review, no new construction ships.
