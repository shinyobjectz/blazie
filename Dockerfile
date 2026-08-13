# Two stages: build with the toolchain, ship without it. The runtime image has
# no compiler, no source, and no package manager — a smaller thing to keep
# patched and a smaller thing to go wrong.

ARG ELIXIR=1.18.4
ARG OTP=27.3.4
ARG DEBIAN=bookworm-20250520-slim

FROM hexpm/elixir:${ELIXIR}-erlang-${OTP}-debian-${DEBIAN} AS build

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
RUN mix compile

# Needed to build; never used at runtime. runtime.exs reads the real one from
# the environment at boot, so this cannot leak into the image as a live secret.
ENV SECRET_KEY_BASE=build-time-placeholder-000000000000000000000000000000000000000000000000000000
RUN mix release

FROM debian:${DEBIAN} AS runtime

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Facts and keys live on a mounted volume, never in the image. A container is
# replaced on every deploy; a ledger is not.
RUN mkdir -p /data/ledgers /data/keys

WORKDIR /app
COPY --from=build /app/_build/prod/rel/blazie ./

# latin1 breaks Elixir string handling; the release must run under UTF-8.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LEDGER_DIR=/data/ledgers \
    KEY_DIR=/data/keys \
    PORT=4000

EXPOSE 4000

# Refuses without a token, which is the cheapest proof it is actually serving.
#
# `/run`, not `/open`. `/open` was retired when `/run` replaced it and this kept
# probing it, so it asked for a 401 and got a 404 — which meant the container had
# been reporting UNHEALTHY on the live node continuously and nothing said so,
# because `--restart always` does not act on health. The CI release gate had the
# identical bug for the identical reason. A check pointing at an endpoint that no
# longer exists does not fail loudly; it just stops being a check.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -sf -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:4000/run \
      -H 'content-type: application/json' -d '{}' | grep -q 401

CMD ["/app/bin/blazie", "start"]
