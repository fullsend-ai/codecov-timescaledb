# TimescaleDB image for PostgreSQL 17.
# Build args hardcoded for Konflux (no dynamic Makefile resolution).

ARG PG_VERSION=17
ARG PG_MAJOR_VERSION=17
ARG TS_VERSION=2.27.0
ARG ALPINE_VERSION=3.23
ARG PGVECTOR_VERSION=v0.8.1
ARG CLANG_VERSION=21
ARG GO_VERSION=1.26.4
############################
# Build tools binaries in separate image
############################
FROM golang:${GO_VERSION}-alpine AS tools

RUN apk update && apk add --no-cache git gcc musl-dev \
    && go install github.com/timescale/timescaledb-tune/cmd/timescaledb-tune@latest \
    && git clone https://github.com/timescale/timescaledb-parallel-copy /build/parallel-copy \
    && cd /build/parallel-copy \
    && go get github.com/jackc/pgx/v5@v5.9.2 && go mod tidy \
    && go install ./cmd/timescaledb-parallel-copy \
    && cd / && rm -rf /build/parallel-copy \
    && go install github.com/tianon/gosu@latest

############################
# Build everything on postgres base
############################
FROM postgres:${PG_VERSION}-alpine${ALPINE_VERSION} AS build
ARG OSS_ONLY

LABEL maintainer="Timescale https://www.timescale.com"

RUN apk update && apk upgrade --no-cache

ARG PG_MAJOR_VERSION
ARG ALPINE_VERSION
RUN set -ex; \
    echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community/" >> /etc/apk/repositories; \
    apk update; \
    if [ "$PG_MAJOR_VERSION" -ge 16 ] && [ "$PG_MAJOR_VERSION" -lt 18 ] ; then \
        apk add --no-cache postgresql${PG_MAJOR_VERSION}-plpython3; \
    fi

ARG PGVECTOR_VERSION
ARG CLANG_VERSION
ARG PG_MAJOR_VERSION
RUN set -ex; \
    apk update; \
    apk add --no-cache --virtual .vector-deps \
        postgresql${PG_MAJOR_VERSION}-dev \
        git \
        build-base \
        clang${CLANG_VERSION} \
        llvm${CLANG_VERSION}-dev \
        llvm${CLANG_VERSION}; \
    git clone --branch ${PGVECTOR_VERSION} https://github.com/pgvector/pgvector.git /build/pgvector; \
    cd /build/pgvector; \
    make OPTFLAGS=""; \
    make install; \
    apk del .vector-deps

COPY docker-entrypoint-initdb.d/* /docker-entrypoint-initdb.d/
COPY --from=tools /go/bin/* /usr/local/bin/

ARG TS_VERSION
RUN set -ex \
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
    && git checkout ${TS_VERSION} \
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
# Final image: single layer from scratch eliminates base image layers
# that contain the vulnerable gosu binary (Go 1.24.6).
# ACS scans each layer independently, so only FROM scratch prevents
# the old gosu from appearing in any scannable layer.
############################
FROM scratch
COPY --from=build / /

ENV LANG=en_US.utf8 \
    PGDATA=/var/lib/postgresql/data \
    PG_MAJOR=17 \
    PG_VERSION=17.10 \
    GOSU_VERSION=1.19 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

STOPSIGNAL SIGINT
EXPOSE 5432
VOLUME /var/lib/postgresql/data
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
