# TimescaleDB image for PostgreSQL 17.
# Build args hardcoded for Konflux (no dynamic Makefile resolution).
#
# Supply-chain pins: base images are digest-pinned and every upstream source
# tree / Go module is pinned to an immutable commit or release version. The
# build fails if a pinned tag no longer resolves to the recorded commit, so
# a moved tag is detected instead of silently building different code.

ARG PG_VERSION=17
ARG PG_MAJOR_VERSION=17
ARG PG_FULL_VERSION=17.12
ARG TS_VERSION=2.27.0
ARG TS_COMMIT=fd7f303ac36df4958c4fceef6917008b095735bf
ARG ALPINE_VERSION=3.23
ARG PGVECTOR_VERSION=v0.8.1
ARG PGVECTOR_COMMIT=778dacf20c07caf904557a88705142631818d8cb
ARG CLANG_VERSION=21
ARG GO_VERSION=1.27.4
ARG TUNE_VERSION=v0.19.1
ARG PARALLEL_COPY_VERSION=v0.14.1
ARG PARALLEL_COPY_COMMIT=2ea6d92131f94967df08d5e70c1c766719eb0287
ARG PGX_VERSION=v5.9.2
ARG GOSU_VERSION=1.20
ARG GOSU_COMMIT=29b939aa5bd4dc588af765b8248f6e39150d2565
############################
# Build tools binaries in separate image
############################
FROM golang:${GO_VERSION}-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS tools

ARG TUNE_VERSION
ARG PARALLEL_COPY_VERSION
ARG PARALLEL_COPY_COMMIT
ARG PGX_VERSION
ARG GOSU_COMMIT

# Fail instead of downloading a different Go toolchain at build time.
ENV GOTOOLCHAIN=local

RUN apk update && apk add --no-cache git gcc musl-dev \
    && go install github.com/timescale/timescaledb-tune/cmd/timescaledb-tune@${TUNE_VERSION} \
    && git clone --branch "${PARALLEL_COPY_VERSION}" --depth 1 https://github.com/timescale/timescaledb-parallel-copy /build/parallel-copy \
    && cd /build/parallel-copy \
    && test "$(git rev-parse HEAD)" = "${PARALLEL_COPY_COMMIT}" \
    && go get github.com/jackc/pgx/v5@${PGX_VERSION} \
    && go mod tidy \
    && go install ./cmd/timescaledb-parallel-copy \
    && cd / && rm -rf /build/parallel-copy \
    && go install github.com/tianon/gosu@${GOSU_COMMIT}

############################
# Build everything on postgres base
############################
FROM postgres:${PG_VERSION}-alpine${ALPINE_VERSION}@sha256:57a828ad76b719bbed499fc30f71754bbe37d78c8c4c990a1a2096380b8d7ca5 AS build
ARG OSS_ONLY

LABEL maintainer="Timescale https://www.timescale.com"

RUN apk update && apk upgrade --no-cache

ARG PG_MAJOR_VERSION
ARG PG_FULL_VERSION
ARG ALPINE_VERSION

# Keep the image metadata (ENV PG_VERSION below) honest: fail if the pinned
# base image is not the PostgreSQL version the image declares.
RUN test "$(pg_config --version | awk '{print $2}')" = "${PG_FULL_VERSION}" \
    || { echo "base image does not provide PostgreSQL ${PG_FULL_VERSION}"; exit 1; }

RUN set -ex; \
    echo "${ALPINE_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+$' || { echo "invalid ALPINE_VERSION: ${ALPINE_VERSION}"; exit 1; }; \
    echo "${PG_MAJOR_VERSION}" | grep -Eq '^[0-9]+$' || { echo "invalid PG_MAJOR_VERSION: ${PG_MAJOR_VERSION}"; exit 1; }; \
    echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community/" >> /etc/apk/repositories; \
    apk update; \
    if [ "$PG_MAJOR_VERSION" -ge 16 ] && [ "$PG_MAJOR_VERSION" -lt 18 ] ; then \
        apk add --no-cache "postgresql${PG_MAJOR_VERSION}-plpython3"; \
    fi

ARG PGVECTOR_VERSION
ARG PGVECTOR_COMMIT
ARG CLANG_VERSION
ARG PG_MAJOR_VERSION
RUN set -ex; \
    echo "${CLANG_VERSION}" | grep -Eq '^[0-9]+$' || { echo "invalid CLANG_VERSION: ${CLANG_VERSION}"; exit 1; }; \
    apk update; \
    apk add --no-cache --virtual .vector-deps \
        "postgresql${PG_MAJOR_VERSION}-dev" \
        git \
        build-base \
        "clang${CLANG_VERSION}" \
        "llvm${CLANG_VERSION}-dev" \
        "llvm${CLANG_VERSION}"; \
    git clone --branch "${PGVECTOR_VERSION}" --depth 1 https://github.com/pgvector/pgvector.git /build/pgvector; \
    cd /build/pgvector; \
    test "$(git rev-parse HEAD)" = "${PGVECTOR_COMMIT}"; \
    make OPTFLAGS=""; \
    make install; \
    cd /; \
    rm -rf /build/pgvector; \
    apk del .vector-deps

COPY docker-entrypoint-initdb.d/* /docker-entrypoint-initdb.d/

# Drop the base image's gosu (built with an older Go toolchain) before
# installing the one built above, so the vulnerable binary is genuinely gone.
RUN rm -f /usr/local/bin/gosu
COPY --from=tools /go/bin/* /usr/local/bin/

ARG TS_VERSION
ARG TS_COMMIT
RUN set -ex \
    && case "${OSS_ONLY}" in ""|" -DAPACHE_ONLY=1") ;; *) echo "invalid OSS_ONLY: ${OSS_ONLY}"; exit 1;; esac \
    && apk add --no-cache --virtual .fetch-deps \
                ca-certificates \
                git \
                openssl \
                openssl-dev \
                tar \
    && mkdir -p /build/ \
    && git clone https://github.com/timescale/timescaledb /build/timescaledb \
    \
    && apk add --no-cache --virtual .build-deps \
                coreutils \
                dpkg-dev dpkg \
                icu-dev \
                gcc \
                libc-dev \
                make \
                cmake \
                util-linux-dev \
    \
    && cd /build/timescaledb && rm -fr build \
    && git checkout "${TS_COMMIT}" \
    && test "$(git rev-parse HEAD)" = "${TS_COMMIT}" \
    && ./bootstrap -DCMAKE_BUILD_TYPE=RelWithDebInfo -DREGRESS_CHECKS=OFF -DTAP_CHECKS=OFF -DGENERATE_DOWNGRADE_SCRIPT=ON -DWARNINGS_AS_ERRORS=OFF -DPROJECT_INSTALL_METHOD="docker"${OSS_ONLY} \
    && cd build && make install \
    && cd ~ \
    \
    && if [ "${OSS_ONLY}" != "" ]; then rm -f $(pg_config --pkglibdir)/timescaledb-tsl-*.so; fi \
    && apk del .fetch-deps .build-deps \
    && rm -rf /build \
    && sed -r -i "s/[#]*\s*(shared_preload_libraries)\s*=\s*'(.*)'/\1 = 'timescaledb,\2'/;s/,'/'/" /usr/local/share/postgresql/postgresql.conf.sample

RUN mkdir -p /var/run/postgresql && chown -R postgres:0 /var/run/postgresql && chmod -R g+rwx /var/run/postgresql && \
    mkdir -p /var/lib/postgresql && chown -R postgres:0 /var/lib/postgresql && chmod -R g+rwx /var/lib/postgresql && \
    chown -R postgres:0 /docker-entrypoint-initdb.d && chmod -R g+rx /docker-entrypoint-initdb.d

############################
# Final image: a single layer from scratch drops the base image layers that
# still contain the postgres image's original gosu binary (built with an
# older Go toolchain), which layer-based scanners report even though that
# binary is removed and replaced above.
#
# NOTE: with a single layer, per-layer scanners cannot see the package set
# underneath. Scan this image's root filesystem / apk database (ACS, or
# Trivy rootfs analysis) instead; a clean layer scan is not evidence of a
# clean image.
############################
FROM scratch
COPY --from=build / /

ARG PG_MAJOR_VERSION
ARG PG_FULL_VERSION
ARG GOSU_VERSION

ENV LANG=en_US.utf8 \
    PGDATA=/var/lib/postgresql/data \
    PG_MAJOR=${PG_MAJOR_VERSION} \
    PG_VERSION=${PG_FULL_VERSION} \
    GOSU_VERSION=${GOSU_VERSION} \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

STOPSIGNAL SIGINT
EXPOSE 5432
VOLUME /var/lib/postgresql/data
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
