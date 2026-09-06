##= BUILDER =##
# Alpine/musl so `--static` produces a genuinely self-contained binary; the
# runner stage then needs nothing but a CA bundle.
FROM crystallang/crystal:1.21.0-alpine AS builder
WORKDIR /gori

# `-dev` packages carry the headers and the .pc files pkg-config reads; the
# `-static` ones carry the .a archives `crystal build --static` actually links.
# Both halves are required — omitting a `-static` package fails at link time,
# not at configure time.
#
#   brotli/zstd  -> src/gori/proxy/codec/{brotli,zstd}.cr @[Link(pkg_config:)]
#   sqlite       -> sqlite3 shard (@[Link("sqlite3")])
#   openssl      -> proxy/tls
#   yaml         -> import/oas.cr
#   gmp          -> `require "big"`
#   zlib         -> Compress::{Deflate,Gzip,Zlib}
#   pcre2, gc    -> Crystal runtime (Regex, GC)
#
# pcre2-dev, gc-dev, yaml-dev and zlib-dev already carry their .a, so they need
# no `-static` sibling; gmp does — `gmp-dev` alone links fine dynamically and
# dies with `ld: cannot find -lgmp` only under `--static`.
RUN apk add --no-cache \
      git pkgconf \
      brotli-dev brotli-static \
      zstd-dev zstd-static \
      sqlite-dev sqlite-static \
      yaml-dev yaml-static \
      zlib-dev zlib-static \
      openssl-dev openssl-libs-static \
      gmp-dev gmp-static \
      pcre2-dev gc-dev

COPY shard.yml shard.lock ./
RUN shards install --production

COPY . .
# `crystal build -o` does not create the output directory, and `bin/` is in
# Dockerfile.dockerignore so `COPY . .` never brings one — without this mkdir the link
# step dies with `ld: cannot open output file /gori/bin/gori`.
#
# Deliberately NO `-Dpreview_mt`: Store, Fuzz::Engine, Miner::Engine and
# Store::SafeRegexp rely on the single-threaded fiber scheduler for their
# unguarded ivars. See the comments in those files before changing this.
RUN mkdir -p /gori/bin && \
    crystal build src/main.cr -o /gori/bin/gori --release --no-debug --static && \
    strip /gori/bin/gori

##= RUNNER =##
FROM alpine:3.23

LABEL org.opencontainers.image.title="gori"
LABEL org.opencontainers.image.description="gori (고리) is a free/open-source TUI web proxy (MITM) written in Crystal."
LABEL org.opencontainers.image.authors="HAHWUL <hahwul@gmail.com>"
LABEL org.opencontainers.image.source="https://github.com/hahwul/gori"
LABEL org.opencontainers.image.documentation="https://github.com/hahwul/gori"
LABEL org.opencontainers.image.licenses="Apache-2.0"

ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

# The binary is static, so this is the whole runtime:
#   ca-certificates  -> verifying upstream TLS
#   tzdata           -> without it /usr/share/zoneinfo is absent, Time::Location
#                       falls back to UTC without erroring, and `-e TZ=Asia/Seoul`
#                       is silently ignored. 1.5 MB buys honest local timestamps.
#   tini             -> see the ENTRYPOINT note below
RUN apk add --no-cache ca-certificates tzdata tini

COPY --from=builder /gori/bin/gori /usr/local/bin/gori

# Settings, the root CA and the per-project SQLite databases all live under
# $GORI_HOME (default ~/.gori). Mount a volume here or the CA is regenerated —
# and must be re-trusted — on every run.
ENV GORI_HOME=/data
# Also the working directory, so a relative path handed to an export or a
# redirect lands in the volume instead of the container's throwaway write layer.
WORKDIR /data
VOLUME ["/data"]

# Default proxy port. Note the default bind host is 127.0.0.1, which is not
# reachable from outside the container: pass `--listen 0.0.0.0` to publish it.
EXPOSE 8070

# No CMD: bare `gori` starts the TUI, which needs a TTY (`docker run --rm -it`).
# Headless subcommands work without one, e.g.
#   docker run --rm -v gori:/data ghcr.io/hahwul/gori run history
#   docker run --rm -i  -v gori:/data ghcr.io/hahwul/gori mcp
#
# tini, not bare `gori`, because gori must not be PID 1. Linux drops any signal
# whose disposition is still the default when it is aimed at PID 1, and both
# shutdown paths rely on exactly that:
#
#   App::SignalGuard restores the terminal and then re-raises the signal at
#   itself so the process dies FROM it and exits the conventional 128+signo
#   (app.cr, REAL_DIE). As PID 1 the re-raise is discarded, so `docker stop`
#   on the TUI exited 1 instead of 143.
#
#   `gori mcp` installs no trap at all, so SIGTERM was dropped outright and
#   `docker stop` burned its whole timeout before SIGKILL (exit 137).
#
# Under tini both exit 143 immediately. `docker run --init` does the same thing
# from the outside; baking it in means nobody has to know that.
ENTRYPOINT ["/sbin/tini", "--", "gori"]
