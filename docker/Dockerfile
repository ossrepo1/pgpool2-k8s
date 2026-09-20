# syntax=docker/dockerfile:1

ARG DEBIAN_VERSION=trixie
ARG PG_MAJOR=18
ARG PGPOOL_VERSION=4.7.2
ARG PGPOOL_SHA256=e72b9d0ff3620f7da7e33a58dda44b77919d056752dc9bd86b2985c4988d1938

FROM debian:${DEBIAN_VERSION}-slim AS builder

ARG PG_MAJOR
ARG PGPOOL_VERSION
ARG PGPOOL_SHA256

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
        https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    . /etc/os-release; \
    printf 'Types: deb\nURIs: https://apt.postgresql.org/pub/repos/apt\nSuites: %s-pgdg\nComponents: main\nArchitectures: %s\nSigned-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc\n' \
        "${VERSION_CODENAME}" "$(dpkg --print-architecture)" \
        > /etc/apt/sources.list.d/pgdg.sources; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        libpam0g-dev \
        libpq-dev \
        libssl-dev \
        "postgresql-server-dev-${PG_MAJOR}" \
        zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"

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

FROM debian:${DEBIAN_VERSION}-slim AS runtime

ARG PG_MAJOR

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
COPY --from=builder /etc/apt/sources.list.d/pgdg.sources /etc/apt/sources.list.d/pgdg.sources

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libpam0g \
        "postgresql-client-${PG_MAJOR}" \
        tzdata; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local /usr/local
COPY --from=builder /usr/share/postgresql/${PG_MAJOR}/extension/pgpool* /usr/share/pgpool-II/pg${PG_MAJOR}/extension/
COPY --from=builder /usr/lib/postgresql/${PG_MAJOR}/lib/pgpool* /usr/share/pgpool-II/pg${PG_MAJOR}/lib/

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN set -eux; \
    chmod 0755 /usr/local/bin/docker-entrypoint.sh; \
    groupadd --gid 20001 pgpool; \
    useradd --uid 20001 --gid 20001 --home-dir /var/lib/pgpool --shell /usr/sbin/nologin pgpool; \
    install -d -o pgpool -g pgpool -m 0755 /var/lib/pgpool /run/pgpool; \
    chown -R pgpool:pgpool /usr/local/etc; \
    ldconfig; \
    if ldd /usr/local/bin/pgpool | grep -q "not found"; then \
        echo "pgpool is missing shared libraries" >&2; \
        ldd /usr/local/bin/pgpool >&2; \
        exit 1; \
    fi

ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"

USER pgpool
WORKDIR /var/lib/pgpool

EXPOSE 9999 9898

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/9999"]

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["pgpool", "-n", "-f", "/usr/local/etc/pgpool.conf"]
