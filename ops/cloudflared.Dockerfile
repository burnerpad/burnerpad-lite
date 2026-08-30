# Temporary compatibility build: exact upstream release source, rebuilt with a patched Go toolchain until
# Cloudflare publishes an official image that passes this repository's high/critical scan. The daily audit
# compares CLOUDFLARED_VERSION with GitHub's newest release; updates are reviewed, never silently deployed.
ARG CLOUDFLARED_VERSION=2026.8.2
ARG UPSTREAM_REVISION=733bfb939963e150dcf5c4faddb1603f744fbc98
FROM golang:1.27.0-bookworm@sha256:ded31c68586d2e49e760acc2e65a884b23d032e9bbbed0ae0c55abd3fcaf4452 AS build

ARG TARGETOS
ARG TARGETARCH
ARG CLOUDFLARED_VERSION
ARG UPSTREAM_REVISION
WORKDIR /src

# Fetch only the release's peeled, immutable commit and build strictly from its vendored dependency tree;
# no Go module is resolved from the network during compilation.
RUN git init . \
    && git remote add origin https://github.com/cloudflare/cloudflared.git \
    && git fetch --depth=1 origin "refs/tags/$CLOUDFLARED_VERSION:refs/tags/$CLOUDFLARED_VERSION" \
    && test "$(git rev-list -n1 "$CLOUDFLARED_VERSION")" = "$UPSTREAM_REVISION" \
    && git checkout --detach "$UPSTREAM_REVISION" \
    && test "$(git rev-parse HEAD)" = "$UPSTREAM_REVISION" \
    && CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
       go build -mod=vendor -trimpath \
       -ldflags="-s -w -X main.Version=$CLOUDFLARED_VERSION -X github.com/cloudflare/cloudflared/metrics.Runtime=virtual" \
       -o /cloudflared ./cmd/cloudflared \
    && sha256sum /cloudflared > /cloudflared.sha256 \
    && go version -m /cloudflared > /cloudflared.buildinfo

# `cloudflared` is built fully static. Use the matching distroless static runtime (CA certificates +
# non-root identity, but no unused OpenSSL shared library); the larger upstream base image carried an
# unfixed high-severity OpenSSL advisory even though this binary never linked it. Digest-pinned.
FROM gcr.io/distroless/static-debian13:nonroot@sha256:1c2c046bc09ed40fad370b599a0b1ae7987f55b01e247cf27a7c27cd97e5bbc7

ARG CLOUDFLARED_VERSION
ARG UPSTREAM_REVISION
ARG BURNERPAD_REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/burnerpad/burnerpad-lite" \
      org.opencontainers.image.title="burnerpad-lite-cloudflared" \
      org.opencontainers.image.version="$CLOUDFLARED_VERSION" \
      org.opencontainers.image.revision="$BURNERPAD_REVISION" \
      org.burnerpad.upstream.source="https://github.com/cloudflare/cloudflared" \
      org.burnerpad.upstream.revision="$UPSTREAM_REVISION"

COPY --from=build --chown=65532:65532 /cloudflared /usr/local/bin/cloudflared
COPY --from=build --chown=65532:65532 /cloudflared.sha256 /cloudflared.buildinfo /usr/local/share/burnerpad/
USER 65532:65532
ENTRYPOINT ["cloudflared", "--no-autoupdate"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["cloudflared", "tunnel", "--metrics", "127.0.0.1:20241", "ready"]
CMD ["version"]
