# ── build ────────────────────────────────────────────────────────────────────
# Build and runtime MUST stay on the SAME Alpine version → the same OpenSSL. The release bundles Erlang's
# `crypto` NIF, which is dynamically linked against libcrypto; if the runtime's OpenSSL is older than the
# build's, the NIF fails to load at boot (e.g. "symbol EVP_MD_CTX_get_size_ex not found"). Both stages are
# pinned to Alpine 3.22.5 (OpenSSL 3.5.x) — bump these two FROM lines together, never independently.
FROM hexpm/elixir:1.18.4-erlang-27.3.4.13-alpine-3.22.5 AS build

RUN apk add --no-cache build-base git
WORKDIR /app

ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs ./
RUN mix deps.get --only prod && mix deps.compile

COPY lib lib
COPY priv priv
# The crypto bundle is a git submodule (priv/static/vendor/crypto-js). The build context must have it
# checked out — run `git submodule update --init` before `docker build`. Fail loud here, not at runtime.
RUN test -f priv/static/vendor/crypto-js/burnerpad-crypto.js \
    || (echo 'ERROR: crypto-js submodule missing — run: git submodule update --init' && exit 1)
RUN mix compile && mix release

# ── runtime ──────────────────────────────────────────────────────────────────
# MUST match the build stage's Alpine/OpenSSL (see note above).
FROM alpine:3.22.5 AS runtime

RUN apk add --no-cache libstdc++ ncurses-libs openssl && \
    adduser -D -h /app app
WORKDIR /app
USER app

COPY --from=build --chown=app:app /app/_build/prod/rel/burnerpad ./

ENV PORT=4000
EXPOSE 4000

CMD ["bin/burnerpad", "start"]
