# syntax=docker/dockerfile:1

# Pgpool-II built from source on Alpine, targeting linux/amd64 so the image runs on the
# amd64 cluster even when it is built on an arm64 workstation (emulated by the builder).
# Run from this directory (docker-entrypoint.sh is copied from the build context):
#
#   docker build --platform linux/amd64 -t pgpool:4.7.2 .
#
# BUILD_PLATFORM defaults to linux/amd64; override for another architecture with
# --build-arg BUILD_PLATFORM=linux/arm64.

ARG BUILD_PLATFORM=linux/amd64

# Alpine package mirror. dl-cdn is the official CDN but can be slow from some networks;
# e.g. --build-arg APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine. Applied in both
# stages, so it also ends up in the runtime image's /etc/apk/repositories.
ARG APK_MIRROR=https://dl-cdn.alpinelinux.org/alpine

ARG PG_MAJOR=18
ARG PGPOOL_VERSION=4.7.2
ARG PGPOOL_SHA256=e72b9d0ff3620f7da7e33a58dda44b77919d056752dc9bd86b2985c4988d1938

FROM --platform=${BUILD_PLATFORM} alpine:latest AS builder

ARG APK_MIRROR
ARG PG_MAJOR
ARG PGPOOL_VERSION
ARG PGPOOL_SHA256

SHELL ["/bin/sh", "-o", "pipefail", "-c"]

# The apk cache mount keeps downloaded packages between builds, so an aborted or repeated
# build does not re-download the toolchain (postgresql-dev pulls clang/llvm, ~250 MB).
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    set -eux; \
    sed -i "s|^https://dl-cdn.alpinelinux.org/alpine|${APK_MIRROR}|" /etc/apk/repositories; \
    apk add \
        build-base \
        curl \
        libpq-dev \
        linux-headers \
        linux-pam-dev \
        openssl-dev \
        "postgresql${PG_MAJOR}-dev" \
        zlib-dev

RUN set -eux; \
    curl -fsSL -o /tmp/pgpool.tar.gz "https://www.pgpool.net/source/pgpool-II-${PGPOOL_VERSION}.tar.gz"; \
    echo "${PGPOOL_SHA256}  /tmp/pgpool.tar.gz" | sha256sum -c -; \
    mkdir -p /tmp/pgpool; \
    tar -xzf /tmp/pgpool.tar.gz -C /tmp/pgpool --strip-components=1; \
    cd /tmp/pgpool; \
    ./configure \
        --prefix=/usr/local \
        --with-openssl \
        --with-pam; \
    make -j"$(nproc)"; \
    make install; \
    for ext in pgpool-recovery pgpool-regclass pgpool_adm; do \
        make -C "src/sql/${ext}" install; \
    done; \
    rm -rf /tmp/pgpool /tmp/pgpool.tar.gz

FROM --platform=${BUILD_PLATFORM} alpine:latest AS runtime

ARG APK_MIRROR
ARG PG_MAJOR

SHELL ["/bin/sh", "-o", "pipefail", "-c"]

# bash is used by docker-entrypoint.sh and the healthcheck; psql and the pcp_* clients are
# used by the chart's reattach CronJob, which runs from this image.
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    set -eux; \
    sed -i "s|^https://dl-cdn.alpinelinux.org/alpine|${APK_MIRROR}|" /etc/apk/repositories; \
    apk add \
        bash \
        ca-certificates \
        libcrypto3 \
        libpq \
        libssl3 \
        linux-pam \
        "postgresql${PG_MAJOR}-client" \
        tzdata

COPY --from=builder /usr/local /usr/local
COPY --from=builder /usr/share/postgresql${PG_MAJOR}/extension/pgpool* /usr/share/pgpool-II/pg${PG_MAJOR}/extension/
COPY --from=builder /usr/lib/postgresql${PG_MAJOR}/pgpool* /usr/share/pgpool-II/pg${PG_MAJOR}/lib/

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN set -eux; \
    chmod 0755 /usr/local/bin/docker-entrypoint.sh; \
    addgroup -g 20001 pgpool; \
    adduser -u 20001 -G pgpool -H -D -s /sbin/nologin -h /var/lib/pgpool pgpool; \
    mkdir -p /var/lib/pgpool /run/pgpool; \
    chown pgpool:pgpool /var/lib/pgpool /run/pgpool; \
    chmod 0755 /var/lib/pgpool /run/pgpool; \
    chown -R pgpool:pgpool /usr/local/etc; \
    if ldd /usr/local/bin/pgpool | grep -q "not found"; then \
        echo "pgpool is missing shared libraries" >&2; \
        ldd /usr/local/bin/pgpool >&2; \
        exit 1; \
    fi

USER pgpool
WORKDIR /var/lib/pgpool

EXPOSE 9999 9898

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/9999"]

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["pgpool", "-n", "-f", "/usr/local/etc/pgpool.conf"]
