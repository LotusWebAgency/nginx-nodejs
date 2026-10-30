ARG WOLFI_IMAGE=cgr.dev/chainguard/wolfi-base:latest
FROM ${WOLFI_IMAGE} AS node-base
RUN apk upgrade --no-cache \
    && apk add --no-cache nodejs ca-certificates-bundle \
    && apk add --no-cache --virtual .strip-deps binutils \
    && strip --strip-unneeded /usr/bin/node \
    && apk del .strip-deps \
    && addgroup -g 1000 node \
    && adduser -D -u 1000 -G node -h /home/node node \
    && mkdir -p /app /app/cache /run/nginx-nodejs /var/lib/nginx-nodejs \
    && chown -R node:node /app /app /run/nginx-nodejs /var/lib/nginx-nodejs
ENV NPM_CONFIG_CACHE=/tmp/npm-cache

FROM node-base AS fluent-bit-build
RUN apk add --no-cache fluent-bit build-base cmake bison flex curl openssl-dev yaml-dev
WORKDIR /build/fluent-bit
# Follow the APK-selected release, with only the collector's required plugins and backlog recovery.
# The HTTP client needs an explicit HA header when AWS's indirect include is disabled.
RUN version=$(fluent-bit --version | sed -n 's/^Fluent Bit v\([0-9][0-9.]*\).*$/\1/p') \
    && test -n "$version" \
    && curl -fsSL "https://codeload.github.com/fluent/fluent-bit/tar.gz/refs/tags/v${version}" -o source.tar.gz \
    && tar -xzf source.tar.gz --strip-components=1 \
    && sed -i '/^#include <fluent-bit\/flb_http_client.h>$/a #include <fluent-bit/flb_upstream_ha.h>' src/flb_http_client.c \
    && cmake -S . -B build \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_C_FLAGS_RELWITHDEBINFO='-Os -DNDEBUG' \
        -DFLB_RELEASE=On -DFLB_DEBUG=Off -DFLB_IPO=Off -DFLB_SECURITY=On \
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
    && build/bin/fluent-bit --version | grep -F "Fluent Bit v${version}" \
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
RUN fluent-bit --version

FROM runtime-packages AS nginx-brotli
RUN nginx -v > /tmp/nginx-version 2>&1 \
    && apk add --no-cache build-base curl brotli-dev pcre2-dev zlib-dev patch nginx-mainline-src \
    && nginx -v 2>&1 | cmp /tmp/nginx-version -
WORKDIR /build
COPY docker/ngx_brotli-ranges.patch ./
ARG NGX_BROTLI_COMMIT=53e0fb55f250f48fe80c0ddbf6c0f7103cdbaae1
ARG NGX_BROTLI_SHA256=27a4352dae4ba4922f9f013f3f0d02359aceeef2701872efa42849c3ba05457a
# The package source follows the installed Nginx ABI; fail if the repository moves mid-build.
RUN curl -fsSL "https://codeload.github.com/google/ngx_brotli/tar.gz/${NGX_BROTLI_COMMIT}" -o brotli.tar.gz \
    && echo "${NGX_BROTLI_SHA256}  brotli.tar.gz" | sha256sum -c - \
    && mkdir ngx_brotli \
    && tar -xzf brotli.tar.gz -C ngx_brotli --strip-components=1 \
    && (cd ngx_brotli && patch -p1 --fuzz=0 < ../ngx_brotli-ranges.patch) \
    && mkdir -p ngx_brotli/deps/brotli/c \
    && ln -s /usr/include ngx_brotli/deps/brotli/c/include \
    && ln -s /usr/lib ngx_brotli/deps/brotli/out \
    && cp -a /usr/src/nginx nginx \
    && cd nginx \
    && ./auto/configure --with-compat --with-threads --with-file-aio --add-dynamic-module=/build/ngx_brotli \
    && make -j2 modules

FROM node-base AS builder
RUN apk add --no-cache npm
WORKDIR /app
USER node

FROM runtime-packages AS runtime
LABEL org.opencontainers.image.title="nginx-nodejs" \
      org.opencontainers.image.description="Rootless Node.js and Nginx runtime with Brotli, s6 supervision, and optional Fluent Bit/Loki logging" \
      org.opencontainers.image.authors="Vasilii Dementev https://vasiliidementev.com" \
      org.opencontainers.image.vendor="Lotus Web Agency" \
      org.opencontainers.image.source="https://github.com/LotusWebAgency/nginx-nodejs" \
      org.opencontainers.image.url="https://hub.docker.com/r/lotuswebagency/nginx-nodejs" \
      org.opencontainers.image.documentation="https://github.com/LotusWebAgency/nginx-nodejs#readme" \
      org.opencontainers.image.licenses="MIT"
COPY --from=nginx-brotli /build/nginx/objs/ngx_http_brotli_filter_module.so /build/nginx/objs/ngx_http_brotli_static_module.so /usr/lib/nginx/modules/
COPY --from=nginx-brotli /build/ngx_brotli/LICENSE /usr/share/licenses/ngx_brotli/LICENSE
RUN printf 'user node;\nerror_log stderr;\nload_module /usr/lib/nginx/modules/ngx_http_brotli_filter_module.so;\nload_module /usr/lib/nginx/modules/ngx_http_brotli_static_module.so;\npid /tmp/nginx.pid;\nevents {}\nhttp {}\n' > /tmp/modules.conf \
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
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 CMD ["node", "/etc/nginx-nodejs/healthcheck.mjs"]
ENTRYPOINT ["/etc/nginx-nodejs/entrypoint.sh"]
CMD ["node", "/usr/share/nginx-nodejs/demo/server.mjs"]
