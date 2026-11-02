# The official image passes the high/critical scan. Pin its release tag and immutable manifest digest
# literally, so Dependabot can propose both together, and add the project's release identity and readiness
# probe. The release derives the version label and peeled upstream commit from this line; CI checks that the
# digest runs the named release. Updates are reviewed pull requests, never silently deployed.
FROM cloudflare/cloudflared:2026.10.6@sha256:004d843fa5fdc3103983fd580ee19fab4a8fa98add31f87249c1659e848c98e0

ARG UPSTREAM_REVISION=unknown
ARG BURNERPAD_REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/burnerpad/burnerpad-lite" \
      org.opencontainers.image.title="burnerpad-lite-cloudflared" \
      org.opencontainers.image.revision="$BURNERPAD_REVISION" \
      org.burnerpad.upstream.source="https://github.com/cloudflare/cloudflared" \
      org.burnerpad.upstream.revision="$UPSTREAM_REVISION"

USER 65532:65532
ENTRYPOINT ["cloudflared", "--no-autoupdate"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["cloudflared", "tunnel", "--metrics", "127.0.0.1:20241", "ready"]
CMD ["version"]
