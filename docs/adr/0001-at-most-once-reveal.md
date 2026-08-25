# ADR-0001: Use an at-most-once destructive reveal claim

- **Status:** Accepted
- **Date:** 2026-08-23
- **Decision-makers:** Burnerpad founder/maintainer

## Context

Burnerpad removes a ciphertext row with one atomic `:ets.take/2` when a client submits the reveal POST.
The operation prevents two concurrent requests from successfully claiming the same ciphertext. It happens
before the HTTP response is completely delivered, so a connection reset can destroy the server copy before
the client receives it.

An idempotent lease/acknowledgement protocol could make delivery retryable, but a claimant could retain the
lease by refusing to acknowledge. It would also turn “one immediate destructive claim” into a more complex
multi-state protocol and lengthen server retention.

## Decision

Keep the atomic destructive take and define the guarantee as **at-most-once server claim**, not exactly-once
delivery or decryption. Do not add a retrieval lease or acknowledgement protocol.

The shared-link GET remains non-burning so ordinary link-preview fetches are safe. Only the JSON reveal POST
claims the ciphertext. Once a response is uncertain or lost, the client must report that the outcome is
unknown; it must not automatically retry or promise recovery. A deliberate manual resubmission may succeed
only if the earlier request did not complete the atomic take. If it did, the resubmission returns the generic
unavailable response. This does not weaken the at-most-one-successful-claim guarantee.

## Alternatives Considered

- **Short retrieval lease plus acknowledgement:** rejected because a claimant can withhold acknowledgement,
  retention becomes stateful, and repeat delivery weakens the selected one-claim model.
- **Read then delete after response:** rejected because concurrent requests can both receive the ciphertext
  and the server cannot reliably know that a response reached the client.
- **Passphrase-derived reveal authorization:** not selected for the current suite/API; the ID remains the
  destructive capability.

## Consequences

- A reset after atomic take can permanently lose an otherwise valid secret.
- `claimed`, `delivered`, and `decrypted` must remain distinct in code, metrics, UI, API, and documentation.
- The browser and CLI require bounded network deadlines and an explicit “outcome unknown” error.
- The browser requires explicit user confirmation before manually resubmitting an uncertain claim; the CLI
  does not resubmit one automatically.
- Tests must prove one successful claim under concurrency and a generic gone response afterward.
- Product copy must not claim guaranteed delivery or “decrypted exactly once.”

## References

- `Burnerpad.Store.reveal/1`
- `POST /api/secrets/:id/reveal`
- [`../PRODUCTION_READINESS_REVIEW.md`](../PRODUCTION_READINESS_REVIEW.md)
