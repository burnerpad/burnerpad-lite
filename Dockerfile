# ── build ────────────────────────────────────────────────────────────────────
# Build and runtime MUST stay on the SAME Ubuntu LTS release → compatible glibc and OpenSSL. The release bundles Erlang's
# `crypto` NIF, which is dynamically linked against libcrypto; if the runtime's OpenSSL is older than the
# build's, the NIF fails to load at boot (e.g. "symbol EVP_MD_CTX_get_size_ex not found"). Both stages use
# Ubuntu Noble; keep them aligned. glibc also avoids OTP 29.0.5's musl alternate-signal-stack startup
# abort on newer Intel hosts. Pinned by DIGEST as well as tag (L11) so tags cannot swap the base images.
FROM hexpm/elixir:1.20.3-erlang-29.0.5-ubuntu-noble-20260810@sha256:f1ee5c316e7716d3c4f5b482cf60d465473d1eb9aef3254a39d6bd9502c80258 AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates git libsctp1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app

ENV MIX_ENV=prod
# Pin the build tools. Compile Hex from its exact source object inside this OTP-pinned builder: a
# precompiled archive may carry BEAM instructions from a newer OTP even when its download is checksummed.
# Rebar's exact upstream escript is checksum-verified. Neither tool ships in the runtime image.
RUN mix archive.install git https://github.com/hexpm/hex.git \
      ref a43131c26aeca06064959297d737991163f5ac5d --force \
    && mix local.rebar rebar3 https://builds.hex.pm/installs/1.18.4/rebar3-3.25.1-otp-28 \
      --sha512 992fd755b7926fae455e5e07d9d195f4d3e7f181609eed1b9cabfe548624df10d148cd4b59bda40bebb185d3d68f9a9fd68a70b294101c8ad9cf0fadcc683d24 --force

# Copy the lock too, so the image builds EXACTLY what was tested + audited (M4), and fail the build on any
# dependency advisory (M9): a vulnerable lock can never be baked into an image.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix hex.audit && mix deps.compile

COPY lib lib
COPY priv priv
# rel/env.sh.eex binds Erlang distribution to loopback (C1) — it MUST be in the build context or
# `mix release` silently generates the default (sname, dist on 0.0.0.0) and C1 is not applied.
COPY rel rel
# The crypto bundle is a git submodule (priv/static/vendor/crypto-js). The build context must have it
# checked out — run `git submodule update --init` before `docker build`. Fail loud here, not at runtime.
RUN test -f priv/static/vendor/crypto-js/burnerpad-crypto.js \
    || (echo 'ERROR: crypto-js submodule missing — run: git submodule update --init' && exit 1)
RUN mix compile --warnings-as-errors \
    && mix release \
    && test -f _build/prod/rel/burnerpad/releases/COOKIE \
    && rm _build/prod/rel/burnerpad/releases/COOKIE

# ── runtime ──────────────────────────────────────────────────────────────────
# MUST match the build stage's Ubuntu/OpenSSL ABI (see note above). Digest-pinned (L11).
FROM ubuntu:noble-20260810@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517 AS runtime

ARG BURNERPAD_REVISION=unknown
ARG BURNERPAD_VERSION=dev
LABEL org.opencontainers.image.source="https://github.com/burnerpad/burnerpad-lite" \
      org.opencontainers.image.title="burnerpad-lite" \
      org.opencontainers.image.revision=$BURNERPAD_REVISION \
      org.opencontainers.image.version=$BURNERPAD_VERSION \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"

RUN apt-get update \
    && apt-get install -y --no-install-recommends busybox-static libsctp1 libstdc++6 libncurses6 libssl3t64 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --user-group --home-dir /app --create-home app
WORKDIR /app
USER app

COPY --from=build --chown=app:app /app/_build/prod/rel/burnerpad ./

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PORT=4000 \
    BURNERPAD_REVISION=$BURNERPAD_REVISION
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD /bin/busybox wget -qO- "http://127.0.0.1:${PORT}/readyz" || exit 1

CMD ["bin/burnerpad", "start"]
