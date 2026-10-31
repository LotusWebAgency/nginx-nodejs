# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# Renovate refreshes the digest; CI verifies its Chainguard signature before building on it.
# `apk upgrade` below still refreshes packages on every rebuild.
ARG WOLFI_IMAGE=cgr.dev/chainguard/wolfi-base:latest@sha256:88a20e2d017bd20cdc0cb3910de603e7bea9512a6c351a8dd3c9df212ab03d73
# Vendored components compiled from source. Declared here so the runtime stage can record them
# in OCI labels; the stages that use them redeclare them.
# renovate: datasource=github-tags depName=fluent/fluent-bit
ARG FLUENT_BIT_VERSION=5.1.5
# sha256 of the codeload tarball: update it by hand in the same PR as the version.
ARG FLUENT_BIT_SHA256=de18660c0d8b077289d29cec6da6d8956b212b4ce75a58e2debe9be78286c621
ARG NGX_BROTLI_COMMIT=53e0fb55f250f48fe80c0ddbf6c0f7103cdbaae1
ARG NGX_BROTLI_SHA256=27a4352dae4ba4922f9f013f3f0d02359aceeef2701872efa42849c3ba05457a
# headers-more v0.41: more_set_headers replaces a header instead of appending, which add_header
# cannot do when Nginx re-runs the header filters for a 416.
ARG HEADERS_MORE_COMMIT=21066f7eed72e4de4f6ec47b93e8d5f36c38b84a
ARG HEADERS_MORE_SHA256=52f3f4dc1b34efa887155e92398052bf477702b2753585fe3482e2dd0136ea62
# Busybox's raw-socket and interface applets give an attacker with code execution a ready-made
# network toolbox and nothing here uses them. Wolfi's busybox already omits nc, wget, telnet,
# ftp*, tftp and httpd; the rest are pruned again after every `apk add`, because busybox's apk
# trigger recreates the links. tests.sh asserts none of these exist.
ARG BUSYBOX_NET_APPLETS="arping dnsdomainname ifconfig ip microcom nc netstat nslookup ping ping6 route telnet traceroute traceroute6 tunctl vconfig wget ftpget ftpput tftp httpd"
ARG NODE_MAJOR=26
FROM ${WOLFI_IMAGE} AS node-base
ARG NODE_MAJOR
RUN apk upgrade --no-cache \
    && apk add --no-cache "nodejs-${NODE_MAJOR}" ca-certificates-bundle \
    && apk add --no-cache --virtual .strip-deps binutils \
    && strip --strip-unneeded /usr/bin/node \
    && apk del .strip-deps \
    && addgroup -g 1000 node \
    && adduser -D -u 1000 -G node -h /home/node node \
    && mkdir -p /app /app/cache /run/nginx-nodejs /var/lib/nginx-nodejs \
    && chown -R node:node /app /app /run/nginx-nodejs /var/lib/nginx-nodejs
ENV NPM_CONFIG_CACHE=/tmp/npm-cache
LABEL com.lotuswebagency.node-major="${NODE_MAJOR}"

FROM node-base AS fluent-bit-build
RUN apk add --no-cache build-base cmake bison flex curl openssl-dev yaml-dev
WORKDIR /build/fluent-bit
# Fluent Bit is compiled from the pinned source tarball at the top of this file, not from the
# APK, so Trivy cannot see it (see SECURITY.md).
ARG FLUENT_BIT_VERSION
ARG FLUENT_BIT_SHA256
# Hardening flags go in through CMAKE_C_FLAGS and -DFLB_SECURITY=Off: FLB_SECURITY=On appends
# -fstack-protector and -D_FORTIFY_SOURCE=1 after ours, which would downgrade them.
# Only the collector's required plugins and backlog recovery are built.
# The HTTP client needs an explicit HA header when AWS's indirect include is disabled.
RUN curl -fsSL "https://codeload.github.com/fluent/fluent-bit/tar.gz/refs/tags/v${FLUENT_BIT_VERSION}" -o source.tar.gz \
    && echo "${FLUENT_BIT_SHA256}  source.tar.gz" | sha256sum -c - \
    && tar -xzf source.tar.gz --strip-components=1 \
    && sed -i '/^#include <fluent-bit\/flb_http_client.h>$/a #include <fluent-bit/flb_upstream_ha.h>' src/flb_http_client.c \
    && hardening='-fstack-protector-strong -D_FORTIFY_SOURCE=3 -fstack-clash-protection -fPIE' \
    && if [ "$(uname -m)" = x86_64 ]; then hardening="$hardening -fcf-protection=full"; fi \
    && cmake -S . -B build \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_C_FLAGS="$hardening" -DCMAKE_C_FLAGS_RELWITHDEBINFO='-Os -DNDEBUG' \
        -DCMAKE_EXE_LINKER_FLAGS='-pie -Wl,-z,relro,-z,now,-z,noexecstack' \
        -DFLB_RELEASE=On -DFLB_DEBUG=Off -DFLB_IPO=Off -DFLB_SECURITY=Off \
        -DFLB_MINIMAL=On -DFLB_IN_TAIL=On -DFLB_IN_STORAGE_BACKLOG=On \
        -DFLB_FILTER_GREP=On -DFLB_FILTER_MODIFY=On -DFLB_FILTER_RECORD_MODIFIER=On \
        -DFLB_OUT_LOKI=On -DFLB_OUT_NULL=On \
        -DFLB_PARSER=On -DFLB_REGEX=On -DFLB_TLS=On -DFLB_SQLDB=On -DFLB_CONFIG_YAML=On \
        -DFLB_SHARED_LIB=Off -DFLB_EXAMPLES=Off \
        -DFLB_LUAJIT=Off -DFLB_WASM=Off -DFLB_WAMRC=Off -DFLB_KAFKA=Off -DFLB_ZIG=Off \
        -DFLB_AWS=Off -DFLB_SIGNV4=Off -DFLB_STREAM_PROCESSOR=Off -DFLB_PROXY_GO=Off \
        -DFLB_CUSTOM_CALYPTIA=Off -DFLB_CHUNK_TRACE=Off -DFLB_BACKTRACE=Off \
        -DFLB_UNICODE_ENCODER=Off -DFLB_RIPSER=Off -DFLB_PROFILES=Off \
    && cmake --build build --target fluent-bit-bin --parallel 2 \
    && strip --strip-unneeded build/bin/fluent-bit \
    && build/bin/fluent-bit --version | grep -F "Fluent Bit v${FLUENT_BIT_VERSION}" \
    && build/bin/fluent-bit --help \
    && LD_TRACE_LOADED_OBJECTS=1 build/bin/fluent-bit \
    && stat -c 'Fluent Bit binary: %s bytes' build/bin/fluent-bit \
    && mkdir -p /licenses/fluent-bit \
    && cp LICENSE /licenses/fluent-bit/ \
    && find lib -type f \( -iname '*license*' -o -iname '*copying*' -o -iname '*notice*' \) \
        -exec sh -c 'for file do mkdir -p "/licenses/fluent-bit/$(dirname "$file")"; cp "$file" "/licenses/fluent-bit/$file"; done' sh '{}' +
RUN readelf -d build/bin/fluent-bit \
    | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/so:\1/p' > runtime-dependencies \
    && test -s runtime-dependencies

FROM node-base AS runtime-packages
RUN --mount=from=fluent-bit-build,source=/build/fluent-bit/runtime-dependencies,target=/tmp/collector-runtime-dependencies \
    apk add --no-cache nginx-mainline s6 brotli $(cat /tmp/collector-runtime-dependencies)
COPY --from=fluent-bit-build /build/fluent-bit/build/bin/fluent-bit /usr/bin/fluent-bit
COPY --from=fluent-bit-build /licenses/fluent-bit/ /usr/share/licenses/fluent-bit/
ARG BUSYBOX_NET_APPLETS
RUN for applet in $BUSYBOX_NET_APPLETS; do \
        for dir in /bin /sbin /usr/bin /usr/sbin; do \
            case "$(readlink "$dir/$applet" 2>/dev/null)" in */busybox) rm -f "$dir/$applet" ;; esac; \
        done; \
    done \
    && fluent-bit --version

FROM runtime-packages AS nginx-brotli
RUN nginx -v > /tmp/nginx-version 2>&1 \
    && apk add --no-cache build-base curl brotli-dev pcre2-dev zlib-dev patch nginx-mainline-src \
    && nginx -v 2>&1 | cmp /tmp/nginx-version -
WORKDIR /build
COPY docker/ngx_brotli-ranges.patch ./
ARG NGX_BROTLI_COMMIT
ARG NGX_BROTLI_SHA256
ARG HEADERS_MORE_COMMIT
ARG HEADERS_MORE_SHA256
# The package source follows the installed Nginx ABI; fail if the repository moves mid-build.
RUN curl -fsSL "https://codeload.github.com/google/ngx_brotli/tar.gz/${NGX_BROTLI_COMMIT}" -o brotli.tar.gz \
    && echo "${NGX_BROTLI_SHA256}  brotli.tar.gz" | sha256sum -c - \
    && mkdir ngx_brotli \
    && tar -xzf brotli.tar.gz -C ngx_brotli --strip-components=1 \
    && (cd ngx_brotli && patch -p1 --fuzz=0 < ../ngx_brotli-ranges.patch) \
    && mkdir -p ngx_brotli/deps/brotli/c \
    && ln -s /usr/include ngx_brotli/deps/brotli/c/include \
    && ln -s /usr/lib ngx_brotli/deps/brotli/out \
    && curl -fsSL "https://codeload.github.com/openresty/headers-more-nginx-module/tar.gz/${HEADERS_MORE_COMMIT}" -o headers-more.tar.gz \
    && echo "${HEADERS_MORE_SHA256}  headers-more.tar.gz" | sha256sum -c - \
    && mkdir headers-more \
    && tar -xzf headers-more.tar.gz -C headers-more --strip-components=1 \
    && cp -a /usr/src/nginx nginx \
    && cd nginx \
    && nginx_args="$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p')" \
    && cc_opt="$(printf '%s\n' "$nginx_args" | sed -n "s/.*--with-cc-opt='\([^']*\)'.*/\1/p")" \
    && ld_opt="$(printf '%s\n' "$nginx_args" | sed -n "s/.*--with-ld-opt='\([^']*\)'.*/\1/p")" \
    && cc_opt="$cc_opt -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=3 -fstack-clash-protection -fPIC" \
    && if [ "$(uname -m)" = x86_64 ]; then cc_opt="$cc_opt -fcf-protection=full"; fi \
    && ld_opt="$ld_opt -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack" \
    && ./auto/configure --with-compat --with-threads --with-file-aio \
        --with-cc-opt="$cc_opt" --with-ld-opt="$ld_opt" --add-dynamic-module=/build/ngx_brotli \
        --add-dynamic-module=/build/headers-more \
    && make -j2 modules

FROM node-base AS builder
ARG WOLFI_IMAGE
LABEL org.opencontainers.image.base.name="${WOLFI_IMAGE%%@*}" \
      org.opencontainers.image.base.digest="${WOLFI_IMAGE##*@}"
RUN apk add --no-cache npm
WORKDIR /app
USER node

FROM runtime-packages AS runtime
ARG WOLFI_IMAGE
ARG FLUENT_BIT_VERSION
ARG NGX_BROTLI_COMMIT
ARG HEADERS_MORE_COMMIT
LABEL org.opencontainers.image.title="nginx-nodejs" \
      org.opencontainers.image.description="Rootless Node.js and Nginx runtime with Brotli, s6 supervision, and optional Fluent Bit/Loki logging" \
      org.opencontainers.image.authors="Vasilii Dementev https://vasiliidementev.com" \
      org.opencontainers.image.vendor="Lotus Web Agency" \
      org.opencontainers.image.source="https://github.com/LotusWebAgency/nginx-nodejs" \
      org.opencontainers.image.url="https://hub.docker.com/r/lotuswebagency/nginx-nodejs" \
      org.opencontainers.image.documentation="https://github.com/LotusWebAgency/nginx-nodejs#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="${WOLFI_IMAGE%%@*}" \
      org.opencontainers.image.base.digest="${WOLFI_IMAGE##*@}" \
      com.lotuswebagency.fluent-bit.version="${FLUENT_BIT_VERSION}" \
      com.lotuswebagency.ngx-brotli.commit="${NGX_BROTLI_COMMIT}" \
      com.lotuswebagency.headers-more.commit="${HEADERS_MORE_COMMIT}"
COPY --from=nginx-brotli /build/nginx/objs/ngx_http_brotli_filter_module.so /build/nginx/objs/ngx_http_brotli_static_module.so /build/nginx/objs/ngx_http_headers_more_filter_module.so /usr/lib/nginx/modules/
COPY --from=nginx-brotli /build/ngx_brotli/LICENSE /usr/share/licenses/ngx_brotli/LICENSE
COPY --from=nginx-brotli /build/headers-more/LICENSE /usr/share/licenses/headers-more-nginx-module/LICENSE
RUN printf 'user node;\nerror_log stderr;\nload_module /usr/lib/nginx/modules/ngx_http_brotli_filter_module.so;\nload_module /usr/lib/nginx/modules/ngx_http_brotli_static_module.so;\nload_module /usr/lib/nginx/modules/ngx_http_headers_more_filter_module.so;\npid /tmp/nginx.pid;\nevents {}\nhttp {}\n' > /tmp/modules.conf \
    && nginx -t -e stderr -c /tmp/modules.conf \
    && rm /tmp/modules.conf
COPY docker/ /etc/nginx-nodejs/
COPY LICENSE /usr/share/licenses/nginx-nodejs/LICENSE
COPY --chown=node:node examples/demo/ /usr/share/nginx-nodejs/demo/
COPY --chown=node:node examples/demo/public/ /app/public/
ENV NODE_ENV=production APP_DIR=/app NODE_PORT=3000 STATIC_ROOT=/app/public \
    NODE_HEALTH_PATH=/healthz RUNTIME_MODE=prod APP_ENV=production \
    LOG_SERVICE=nginx-nodejs LOKI_ENABLED=0
WORKDIR /app
USER node
EXPOSE 8080
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --start-interval=1s --retries=3 CMD ["env", "-u", "NODE_OPTIONS", "node", "--max-semi-space-size=1", "--max-old-space-size=32", "/etc/nginx-nodejs/healthcheck.mjs"]
ENTRYPOINT ["/etc/nginx-nodejs/entrypoint.sh"]
CMD ["node", "/usr/share/nginx-nodejs/demo/server.mjs"]
