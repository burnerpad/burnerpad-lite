# The official image passes the high/critical scan. Pin its immutable manifest digest and add the
# project's release identity and readiness probe. The daily audit checks for newer upstream releases;
# updates to the version, digest, and upstream revision are reviewed, never silently deployed.
ARG CLOUDFLARED_VERSION=2026.9.3
ARG UPSTREAM_REVISION=96d39adbc812dc7363834bda908970c1a2560a72
FROM cloudflare/cloudflared:${CLOUDFLARED_VERSION}@sha256:072c067d25ccbe61d46e18f0d0723255f2bb5304f7317caa95b27031520ff92c

ARG CLOUDFLARED_VERSION
ARG UPSTREAM_REVISION
ARG BURNERPAD_REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/burnerpad/burnerpad-lite" \
      org.opencontainers.image.title="burnerpad-lite-cloudflared" \
      org.opencontainers.image.version="$CLOUDFLARED_VERSION" \
      org.opencontainers.image.revision="$BURNERPAD_REVISION" \
      org.burnerpad.upstream.source="https://github.com/cloudflare/cloudflared" \
      org.burnerpad.upstream.revision="$UPSTREAM_REVISION"

USER 65532:65532
ENTRYPOINT ["cloudflared", "--no-autoupdate"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["cloudflared", "tunnel", "--metrics", "127.0.0.1:20241", "ready"]
CMD ["version"]
