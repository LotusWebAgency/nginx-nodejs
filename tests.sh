#!/usr/bin/env bash
# Behavior tests for an already-built image; CI runs them before Trivy and publish.
#
#   IMAGE=<ref> ./tests.sh                   runtime image
#   IMAGE=<ref> TARGET=builder ./tests.sh    builder image
#   NODE_MAJOR=<n>                           also assert the image runs that Node major
#
# Every container runs with --network none: requests are made from inside the
# container, and the Loki mock listens on the container's own loopback.
# jq filters and literal ${...} canaries are single-quoted on purpose.
# shellcheck disable=SC2016
set -euo pipefail

IMAGE="${IMAGE:?set IMAGE to the image under test}"
TARGET="${TARGET:-runtime}"
NODE_MAJOR="${NODE_MAJOR:-}"
LABEL="nginx-nodejs.tests=$$"
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok   - $1"; }
not_ok() { fail=$((fail + 1)); echo "FAIL - $1" >&2; }
check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else not_ok "$name"; fi
}
finish() {
    echo "$pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}
cleanup() {
    docker ps -aq --filter "label=$LABEL" | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker volume ls -q --filter "label=$LABEL" | xargs -r docker volume rm >/dev/null 2>&1 || true
    [ -z "${fixture:-}" ] || rm -rf "$fixture"
    [ -z "${elf_dir:-}" ] || rm -rf "$elf_dir"
}
trap cleanup EXIT

node_major_is() {
    docker run --rm --init --network none --label "$LABEL" --entrypoint /usr/bin/timeout "$IMAGE" 20 \
        node -e "process.exit(process.versions.node.startsWith('$NODE_MAJOR.') ? 0 : 1)"
}

if [ "$TARGET" = builder ]; then
    check "builder: node and npm run as UID 1000 without nginx" \
        docker run --rm --init --network none --label "$LABEL" --entrypoint /usr/bin/timeout "$IMAGE" 20 \
        sh -c 'node --version && npm --version && test "$(id -u)" = 1000 && ! command -v nginx'
    [ -z "$NODE_MAJOR" ] || check "builder: node is major $NODE_MAJOR" node_major_is
    finish
    exit
fi
[ "$TARGET" = runtime ] || { echo "TARGET must be runtime or builder" >&2; exit 2; }

# One HTTP request from inside container $1 without decompressing, printed as
# JSON: {status, headers, raw, body, decoded}. `raw` keeps duplicate headers that `headers` merges.
# Args: container method path [headers-json [source-address]]. Any 127.0.0.0/8 address reaches Nginx.
read -r -d '' PROBE <<'JS' || true
const http = require('node:http');
const zlib = require('node:zlib');
const [method, path, headers = '{}', localAddress = ''] = process.argv.slice(1);
const request = http.request({ host: '127.0.0.1', port: 8080, method, path, headers: JSON.parse(headers), ...(localAddress && { localAddress }), timeout: 5000 }, response => {
  const chunks = [];
  response.on('data', chunk => chunks.push(chunk));
  response.on('end', () => {
    const raw = Buffer.concat(chunks);
    const encoding = response.headers['content-encoding'];
    let decoded = raw;
    try { decoded = encoding === 'br' ? zlib.brotliDecompressSync(raw) : encoding === 'gzip' ? zlib.gunzipSync(raw) : raw; } catch {}
    console.log(JSON.stringify({ status: response.statusCode, headers: response.headers, raw: response.rawHeaders, body: raw.toString('utf8'), decoded: decoded.toString('utf8') }));
  });
});
request.on('timeout', () => request.destroy(new Error('timeout')));
request.on('error', error => { console.error(error.message); process.exit(1); });
request.end();
JS
probe() {
    local container="$1"; shift
    docker exec "$container" node -e "$PROBE" "$@"
}
# expect <name> <container> <jq-filter> <method> <path> [headers-json [source-address]]
expect() {
    local name="$1" container="$2" filter="$3"; shift 3
    local out
    if out="$(probe "$container" "$@")" && jq -e "$filter" >/dev/null <<<"$out"; then ok "$name"; else not_ok "$name"; echo "  got: ${out:-<no response>}" | cut -c1-600 >&2; fi
}
wait_healthy() {
    local i
    for i in $(seq 1 60); do
        docker exec "$1" node /etc/nginx-nodejs/healthcheck.mjs >/dev/null 2>&1 && return 0
        [ "$(docker inspect -f '{{.State.Running}}' "$1")" = true ] || return 1
        sleep 1
    done
    return 1
}
# jq helper for filters: how many times the response carried header $k.
HDR='def n($k): [range(0; .raw | length; 2) as $i | .raw[$i] | ascii_downcase | select(. == $k)] | length;'
once='n("x-content-type-options") == 1 and n("x-frame-options") == 1 and n("referrer-policy") == 1 and n("x-request-id") == 1 and n("cache-control") == 1'
wait_health_status() {
    local i
    for i in $(seq 1 60); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$1")" = healthy ] && return 0
        sleep 1
    done
    return 1
}
exit_code() {
    timeout 60 docker wait "$1"
}

# ------------------------------------------------------- hardened deployment
# The flags documented in README.md "Hardened deployment"; the fixture container below runs with
# exactly these, so the gate proves the image works locked down.
HARDENED_FLAGS=(--read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit 256
    --tmpfs "/run/nginx-nodejs:noexec,nosuid,nodev,uid=1000,gid=1000,mode=0700"
    --tmpfs "/tmp:noexec,nosuid,nodev,uid=1000,gid=1000,mode=1777")

# ---------------------------------------------------------- binary hardening
# Compiled here, not packaged, so the flags are asserted on the produced files. readelf is not in
# the image: copy the files out and read them on the host (GitHub's ubuntu runners have binutils).
command -v readelf >/dev/null || { echo "readelf (binutils) is required on the host" >&2; exit 2; }
elf_dir="$(mktemp -d)"
elf_source="$(docker create --label "$LABEL" "$IMAGE")"
nginx_modules=(ngx_http_brotli_filter_module ngx_http_brotli_static_module ngx_http_headers_more_filter_module)
docker cp "$elf_source:/usr/bin/fluent-bit" "$elf_dir/" >/dev/null
for module in "${nginx_modules[@]}"; do
    docker cp "$elf_source:/usr/lib/nginx/modules/$module.so" "$elf_dir/" >/dev/null
done
docker rm "$elf_source" >/dev/null
machine="$(readelf -hW "$elf_dir/fluent-bit" | sed -n 's/^ *Machine: *//p')"

# elf_hardened <file> <exe|so>: PIE (executables) or no text relocations (shared objects), full
# RELRO, non-executable stack, stack protector.
# Output is captured before grepping: under pipefail, `readelf | grep -q` fails on SIGPIPE.
elf_hardened() {
    local file="$1" kind="$2" header program dynamic symbols
    header="$(readelf -hW "$file")" && program="$(readelf -lW "$file")" \
        && dynamic="$(readelf -dW "$file")" && symbols="$(readelf -sW --dyn-syms "$file")" || return 1
    grep -q 'Program Headers:' <<<"$program" || return 1
    if [ "$kind" = exe ]; then
        grep -qE '^ *Type: +DYN \(Position-Independent Executable' <<<"$header" || return 1
    else
        grep -qE '^ *Type: +DYN \(Shared object' <<<"$header" || return 1
        ! grep -q 'TEXTREL' <<<"$dynamic" || return 1
    fi
    grep -q 'GNU_RELRO' <<<"$program" || return 1
    grep -qE 'BIND_NOW|FLAGS_1.*\bNOW\b' <<<"$dynamic" || return 1
    grep -qE 'GNU_STACK.* RW +' <<<"$program" || return 1
    grep -q '__stack_chk_fail' <<<"$symbols" || return 1
}
# elf_fortified <file>: fortified libc calls, i.e. __*_chk among the dynamic symbols. This shows
# that fortification was on (any level); it cannot tell _FORTIFY_SOURCE=1 from 3.
elf_fortified() {
    local symbols
    symbols="$(readelf -sW --dyn-syms "$1")" || return 1
    grep -qE ' __[a-z_0-9]+_chk(@| |$)' <<<"$symbols"
}
# elf_ibt <file>: the x86 feature note marks the file IBT-compatible (amd64 only).
elf_ibt() {
    local notes
    notes="$(readelf -nW "$1")" || return 1
    grep -E 'x86 feature' <<<"$notes" | grep -q 'IBT'
}
check "fluent-bit: PIE, full RELRO, non-exec stack, stack protector" elf_hardened "$elf_dir/fluent-bit" exe
check "fluent-bit: fortified libc calls (__*_chk imports)" elf_fortified "$elf_dir/fluent-bit"
for module in "${nginx_modules[@]}"; do
    check "$module.so: no text relocations, full RELRO, non-exec stack, stack protector" elf_hardened "$elf_dir/$module.so" so
    # Fortification only shows as __*_chk imports when the compiler could not prove a size; a module
    # without any has nothing to observe, so only a module that imports them is asserted.
    module_symbols="$(readelf -sW --dyn-syms "$elf_dir/$module.so")"
    if grep -qE ' __[a-z_0-9]+_chk(@| |$)' <<<"$module_symbols"; then
        check "$module.so: fortified libc calls (__*_chk imports)" elf_fortified "$elf_dir/$module.so"
    else
        echo "skip - $module.so: no fortifiable libc imports to observe"
    fi
done
if grep -q 'X86-64' <<<"$machine"; then
    check "fluent-bit: IBT landing-pad note" elf_ibt "$elf_dir/fluent-bit"
fi

# ------------------------------------------------------------------ demo app
demo="$(docker run -d --init --network none --label "$LABEL" --stop-timeout 45 "$IMAGE")"
check "demo: healthcheck passes" wait_healthy "$demo"
check "runs as UID/GID 1000" sh -c "[ \"\$(docker exec $demo id -u):\$(docker exec $demo id -g)\" = 1000:1000 ]"
[ -z "$NODE_MAJOR" ] || check "node is major $NODE_MAJOR" node_major_is
check "no setuid/setgid files" sh -c "[ -z \"\$(docker exec $demo find / -xdev -perm /6000 -type f)\" ]"
busybox_net_applets="$(sed -n 's/^ARG BUSYBOX_NET_APPLETS="\(.*\)"$/\1/p' "$(dirname "$0")/Dockerfile")"
[ -n "$busybox_net_applets" ] || { echo "BUSYBOX_NET_APPLETS not found in the Dockerfile" >&2; exit 2; }
net_applets="$(docker exec "$demo" sh -c 'for applet in $1; do for dir in /bin /sbin /usr/bin /usr/sbin; do if [ -e "$dir/$applet" ] || [ -L "$dir/$applet" ]; then echo "$dir/$applet"; fi; done; done' sh "$busybox_net_applets")"
check "busybox network applets are pruned${net_applets:+ (still present: $net_applets)}" test -z "$net_applets"
check "wget and nc are not available" sh -c "! docker exec $demo sh -c 'command -v wget || command -v nc'"
expect "demo: Node answers /" "$demo" '.status == 200 and (.body | startswith("nginx-nodejs is running")) and .headers["cache-control"] == "no-store" and (.headers["x-request-id"] | length > 0)' GET /
expect "demo: static file from STATIC_ROOT" "$demo" '.status == 200 and .headers["cache-control"] == "public, max-age=0"' GET /demo.txt
docker restart -t 45 "$demo" >/dev/null
check "restart without a runtime tmpfs comes back healthy" wait_healthy "$demo"
docker rm -f "$demo" >/dev/null

# --------------------------------------------------------------- fixture app
fixture="$(mktemp -d)"
public="$fixture/.output/public"
mkdir -p "$public/assets" "$public/images" "$public/docs" "$public/node_modules/pkg"
asset="$(for i in $(seq 1 80); do echo "export const value$i = 'nginx-nodejs compression fixture line $i';"; done)"
printf '%s\n' "$asset" > "$public/assets/app.0123abcd.js"
printf '/* precompressed sibling */\n' | gzip -9 > "$public/assets/app.0123abcd.js.gz"
printf '/* precompressed br sibling */\n' | docker run --rm -i --network none --label "$LABEL" --user "$(id -u):$(id -g)" --entrypoint node "$IMAGE" -e \
    "process.stdout.write(require('node:zlib').brotliCompressSync(require('node:fs').readFileSync(0)))" > "$public/assets/app.0123abcd.js.br"
printf '<svg xmlns="http://www.w3.org/2000/svg">%s</svg>\n' "$(printf '<rect width="1" height="1"/>%.0s' $(seq 1 40))" > "$public/images/logo.svg"
printf 'license text\n' > "$public/LICENSE"
printf '<!doctype html><title>docs</title>\n' > "$public/docs/index.html"
printf '{}\n' > "$public/assets/app.0123abcd.js.map"
# Symlinks: one to a root-owned file outside the root (must not be served), one to a file of the
# same owner inside it (may be). Root-owned links would be same-owner as /etc/passwd, so skip as root.
ln -s /etc/passwd "$public/leak.txt"
ln -s /etc/passwd "$public/assets/leak.js"
ln -s LICENSE "$public/license-link"
printf 'SECRET=1\n' > "$public/.env"
printf 'module.exports = 1;\n' > "$public/node_modules/pkg/index.js"
cat > "$fixture/server.mjs" <<'JS'
import { createServer } from 'node:http';
import v8 from 'node:v8';

const port = Number(process.env.PORT);
let connections = 0;
const server = createServer((request, response) => {
  switch (request.url) {
    case '/heap':
      response.writeHead(200);
      return response.end(String(v8.getHeapStatistics().heap_size_limit));
    case '/connections':
      response.writeHead(200);
      return response.end(String(connections));
    case '/node-options':
      response.writeHead(200);
      return response.end(JSON.stringify({ options: process.env.NODE_OPTIONS ?? null, appOptions: process.env.NODE_APP_OPTIONS ?? null }));
    case '/ready':
      response.writeHead(200);
      return response.end('ready');
    case '/echo':
      response.writeHead(200, { 'Content-Type': 'application/json', 'Content-Security-Policy': "default-src 'self'" });
      return response.end(JSON.stringify({ headers: request.headers, argv: process.argv.slice(2), cwd: process.cwd(), port }));
    case '/cached':
      response.writeHead(200, { 'Cache-Control': 'public, max-age=60' });
      return response.end('cached');
    case '/boom':
      response.writeHead(500, { 'Cache-Control': 'public, max-age=60' });
      return response.end('boom');
    case '/leak':
      console.log(JSON.stringify({ event: 'http_request', requestId: '0123456789abcdef0123', method: 'GET', status: 200, durationMs: 1, token: 'CANARY_JSON_FIELD' }));
      console.log(JSON.stringify({ event: 'unknown_event', secret: 'CANARY_UNKNOWN_EVENT' }));
      console.error('db password="CANARY_QUOTED" rest of line');
      console.error('Authorization: Bearer CANARY_BEARER');
      response.writeHead(200);
      return response.end('ok');
    case '/exit':
      response.writeHead(200);
      response.end('bye');
      return setTimeout(() => process.exit(3), 50);
    default:
      response.writeHead(404);
      return response.end('not found');
  }
});
server.on('connection', () => { connections += 1; });
server.on('upgrade', (request, socket) => {
  socket.end('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\nupgraded');
});
server.listen(port, process.env.HOST);
JS
cat > "$fixture/marker.cjs" <<'JS'
require('node:fs').appendFileSync('/tmp/markers', `${process.argv[1] ?? '-e'}\n`);
JS
cat > "$fixture/filters.json" <<'JSON'
[{"name":"modify","add":"application fixture","rename":"durationMs duration_ms"}]
JSON
cat > "$fixture/loki.cjs" <<'JS'
const { createServer } = require('node:http');
const { appendFileSync } = require('node:fs');
createServer((request, response) => {
  const chunks = [];
  request.on('data', chunk => chunks.push(chunk));
  request.on('end', () => {
    appendFileSync('/tmp/loki.jsonl', JSON.stringify({ url: request.url, headers: request.headers, body: Buffer.concat(chunks).toString('utf8') }) + '\n');
    response.writeHead(204);
    response.end();
  });
}).listen(3100, '127.0.0.1');
JS
chmod -R a+rX "$fixture"

docker volume create --label "$LABEL" "nginx-nodejs-tests-$$" >/dev/null
app="$(docker run -d --init --network none --label "$LABEL" --stop-timeout 45 "${HARDENED_FLAGS[@]}" \
    -v "nginx-nodejs-tests-$$:/var/lib/nginx-nodejs" \
    -v "$fixture:/fixture:ro" \
    -e APP_DIR=/fixture -e STATIC_ROOT=/fixture/.output/public \
    -e NODE_PORT=3007 -e NODE_HEALTH_PATH=/ready -e PUBLIC_SCHEME=https \
    -e LOG_SERVICE=fixture-app -e APP_ENV=ci \
    -e FLUENT_BIT_FILTERS_FILE=/fixture/filters.json \
    -e LOKI_ENABLED=1 -e LOKI_HOST=127.0.0.1 -e LOKI_PORT=3100 \
    -e 'LOKI_BEARER_TOKEN=literal${HOME}token' -e LOKI_TENANT_ID=tenant-ci \
    "$IMAGE" node /fixture/server.mjs '$HOME' 'two words')"
docker exec -d "$app" node /fixture/loki.cjs
check "hardened run flags: healthcheck passes with collector enabled" wait_healthy "$app"

expect "custom argv is passed literally, cwd is APP_DIR, port is NODE_PORT" "$app" \
    '.status == 200 and (.body | fromjson | .argv == ["$HOME", "two words"] and .cwd == "/fixture" and .port == 3007)' GET /echo
expect "forged X-Forwarded-For replaced, PUBLIC_SCHEME forwarded" "$app" \
    '.body | fromjson | .headers["x-forwarded-for"] == "127.0.0.1" and .headers["x-forwarded-proto"] == "https"' \
    GET /echo '{"X-Forwarded-For":"203.0.113.9","X-Forwarded-Proto":"http"}'
expect "security headers added, application CSP kept" "$app" \
    '.headers["x-content-type-options"] == "nosniff" and .headers["x-frame-options"] == "SAMEORIGIN" and .headers["referrer-policy"] == "strict-origin-when-cross-origin" and .headers["content-security-policy"] == "default-src '"'self'"'"' GET /echo
expect "upstream Cache-Control kept" "$app" '.headers["cache-control"] == "public, max-age=60"' GET /cached
expect "error responses are no-store" "$app" '.status == 500 and .headers["cache-control"] == "no-store"' GET /boom
expect "/assets/ is immutable" "$app" '.status == 200 and .headers["cache-control"] == "public, max-age=31536000, immutable"' GET /assets/app.0123abcd.js
expect "other static files revalidate" "$app" '.status == 200 and .headers["cache-control"] == "public, max-age=0"' GET /images/logo.svg
expect "extensionless static file served before Node" "$app" '.status == 200 and .body == "license text\n"' GET /LICENSE
expect "directory index.html" "$app" '.status == 200 and (.body | contains("<title>docs</title>"))' GET /docs/
expect "missing static asset is 404, not Node" "$app" '.status == 404 and .body != "not found"' GET /assets/missing.js
expect "runtime brotli" "$app" '.headers["content-encoding"] == "br" and (.decoded | contains("<svg"))' GET /images/logo.svg '{"Accept-Encoding":"br"}'
expect "runtime gzip" "$app" '.headers["content-encoding"] == "gzip" and (.decoded | contains("<svg"))' GET /images/logo.svg '{"Accept-Encoding":"gzip"}'
expect "precompressed .gz sibling preferred" "$app" '.headers["content-encoding"] == "gzip" and .decoded == "/* precompressed sibling */\n"' GET /assets/app.0123abcd.js '{"Accept-Encoding":"gzip"}'
expect "byte range" "$app" '.status == 206 and .body == "license"' GET /LICENSE '{"Range":"bytes=0-6"}'
expect "precompressed .br sibling preferred" "$app" '.headers["content-encoding"] == "br" and .decoded == "/* precompressed br sibling */\n"' GET /assets/app.0123abcd.js '{"Accept-Encoding":"br"}'
expect "byte range on a precompressed .gz sibling" "$app" '.status == 206 and .headers["content-encoding"] == "gzip" and (.headers["content-range"] | startswith("bytes 0-4/"))' GET /assets/app.0123abcd.js '{"Accept-Encoding":"gzip","Range":"bytes=0-4"}'
expect "byte range on a precompressed .br sibling" "$app" '.status == 206 and .headers["content-encoding"] == "br" and (.headers["content-range"] | startswith("bytes 0-4/"))' GET /assets/app.0123abcd.js '{"Accept-Encoding":"br","Range":"bytes=0-4"}'
expect "unsatisfiable range on a .br sibling is a plain 416" "$app" '.status == 416 and (.headers["content-encoding"] == null)' GET /assets/app.0123abcd.js '{"Accept-Encoding":"br","Range":"bytes=99999-"}'
expect "multi-range request is served whole (max_ranges 1), not as multipart" "$app" '.status == 200 and .body == "license text\n" and .headers["content-type"] == "application/octet-stream"' GET /LICENSE '{"Range":"bytes=0-1,3-4"}'
expect "Range request still falls back to Node" "$app" '.status == 200 and (.body | fromjson | .port == 3007)' GET /echo '{"Range":"bytes=0-9"}'
expect "container health route answers on loopback" "$app" '.status == 200' GET /__container_health
expect "container health route refuses another peer address" "$app" '.status == 404' GET /__container_health '{}' 127.0.0.2
expect "each header once on a static 200" "$app" "$HDR"' .status == 200 and '"$once"' and .headers["cache-control"] == "public, max-age=31536000, immutable" and .headers["x-content-type-options"] == "nosniff"' GET /assets/app.0123abcd.js
expect "each header once on an unsatisfiable static range (416), Cache-Control no-store" "$app" "$HDR"' .status == 416 and '"$once"' and .headers["cache-control"] == "no-store" and .headers["x-content-type-options"] == "nosniff" and .headers["x-frame-options"] == "SAMEORIGIN" and .headers["referrer-policy"] == "strict-origin-when-cross-origin"' GET /assets/app.0123abcd.js '{"Range":"bytes=99999-"}'
expect "each header once on a 416 for a non-asset static file" "$app" "$HDR"' .status == 416 and '"$once"' and .headers["cache-control"] == "no-store"' GET /LICENSE '{"Range":"bytes=99999-"}'
expect "each header once on a 206 static response" "$app" "$HDR"' .status == 206 and '"$once"' and .headers["cache-control"] == "public, max-age=31536000, immutable"' GET /assets/app.0123abcd.js '{"Range":"bytes=0-4"}'
expect "each header once on a static 404" "$app" "$HDR"' .status == 404 and '"$once"' and .headers["cache-control"] == "no-store"' GET /assets/missing.js
expect "each header once on a Node response" "$app" "$HDR"' .status == 200 and '"$once"' and .headers["cache-control"] == "public, max-age=60"' GET /cached
expect "each header once on a Node error" "$app" "$HDR"' .status == 500 and '"$once"' and .headers["cache-control"] == "no-store"' GET /boom
if [ "$(id -u)" != 0 ]; then
    expect "symlink out of STATIC_ROOT is not served (served by Node as 404)" "$app" '.status == 404 and (.body | contains("root:") | not)' GET /leak.txt
    expect "symlink out of STATIC_ROOT under /assets/ is 404" "$app" '.status == 404 and (.body | contains("root:") | not)' GET /assets/leak.js
fi
expect "symlink to a file of the same owner inside the root is served" "$app" '.status == 200 and .body == "license text\n"' GET /license-link
check "WebSocket upgrade passes through" docker exec "$app" node -e "
const http = require('node:http');
http.request({ host: '127.0.0.1', port: 8080, path: '/ws', headers: { Connection: 'Upgrade', Upgrade: 'websocket' }, timeout: 5000 })
  .on('upgrade', (response, socket, head) => {
    let body = head.toString();
    socket.on('data', chunk => { body += chunk; });
    socket.on('end', () => process.exit(response.statusCode === 101 && body.includes('upgraded') ? 0 : 1));
  })
  .on('response', () => process.exit(1))
  .on('error', () => process.exit(1))
  .end();"
before="$(probe "$app" GET /connections | jq -r .body)"
for i in $(seq 1 30); do probe "$app" GET /ready >/dev/null; done
after="$(probe "$app" GET /connections | jq -r .body)"
check "upstream connections are reused (30 requests opened $((after - before)))" test "$((after - before))" -le 6
etag="$(probe "$app" GET /LICENSE | jq -r '.headers.etag')" || etag=""
expect "conditional request returns 304" "$app" '.status == 304' GET /LICENSE "{\"If-None-Match\":$(jq -Rn --arg e "$etag" '$e')}"
for path in /.env /node_modules/pkg/index.js /assets/app.0123abcd.js.map /assets/app.0123abcd.js.gz; do
    expect "blocked: $path" "$app" '.status == 404' GET "$path"
done

probe "$app" GET /leak >/dev/null || not_ok "leak route answers"
found=0
for i in $(seq 1 30); do
    if docker exec "$app" sh -c 'grep -q fixture-app /tmp/loki.jsonl 2>/dev/null && grep -q 0123456789abcdef0123 /tmp/loki.jsonl'; then found=1; break; fi
    sleep 1
done
check "Loki receives the application event" test "$found" = 1
loki="$(docker exec "$app" cat /tmp/loki.jsonl 2>/dev/null || true)"
check "Loki: literal bearer token, tenant header" jq -se 'any(.[]; .headers.authorization == "Bearer literal${HOME}token" and .headers["x-scope-orgid"] == "tenant-ci")' <<<"$loki"
check "Loki: service/environment labels and mounted filters applied" jq -se '[.[] | .body | fromjson | .streams[]] | any(.stream.service == "fixture-app" and .stream.environment == "ci" and any(.values[]; .[1] | fromjson | .application == "fixture" and has("duration_ms")))' <<<"$loki"
stored="$(docker exec "$app" sh -c 'cat /var/lib/nginx-nodejs/logs/*/current')"
check "persisted logs contain the request" grep -q 0123456789abcdef0123 <<<"$stored"
check "no secret canary in persisted logs or Loki" sh -c '! grep -q CANARY' <<<"$stored$loki"

probe "$app" GET /exit >/dev/null || true
check "Node exit stops the container with status 1" test "$(exit_code "$app")" = 1

# ------------------------------------------------------- resource limits
# Container limits: 2 CPUs give 2 workers, 512 MB give a heap near 75% of what is left after the allowance.
limited="$(docker run -d --init --network none --label "$LABEL" --stop-timeout 45 --cpus 2 --memory 512m --read-only \
    --tmpfs /run/nginx-nodejs:uid=1000,gid=1000,mode=0700 --tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
    --tmpfs /var/lib/nginx-nodejs:uid=1000,gid=1000,mode=0700 -v "$fixture:/fixture:ro" \
    -e APP_DIR=/fixture -e STATIC_ROOT=/fixture/.output/public -e NODE_PORT=3007 -e NODE_HEALTH_PATH=/ready \
    "$IMAGE" node /fixture/server.mjs)"
check "limited: healthcheck passes" wait_healthy "$limited"
workers() { docker exec "$1" ps -o args | grep -c 'nginx: worker'; }
check "limited: --cpus 2 gives 2 Nginx workers" test "$(workers "$limited")" = 2
expect "limited: --memory 512m caps the app heap" "$limited" '(.body | tonumber) > 250000000 and (.body | tonumber) < 330000000' GET /heap
docker rm -f "$limited" >/dev/null
override="$(docker run -d --init --network none --label "$LABEL" --stop-timeout 45 --cpus 2 --memory 512m --read-only \
    --tmpfs /run/nginx-nodejs:uid=1000,gid=1000,mode=0700 --tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
    --tmpfs /var/lib/nginx-nodejs:uid=1000,gid=1000,mode=0700 -v "$fixture:/fixture:ro" \
    -e APP_DIR=/fixture -e STATIC_ROOT=/fixture/.output/public -e NODE_PORT=3007 -e NODE_HEALTH_PATH=/ready \
    -e NGINX_WORKER_PROCESSES=3 -e NODE_MAX_OLD_SPACE_SIZE=96 \
    "$IMAGE" node /fixture/server.mjs)"
check "override: healthcheck passes" wait_healthy "$override"
check "override: NGINX_WORKER_PROCESSES=3 gives 3 workers" test "$(workers "$override")" = 3
expect "override: NODE_MAX_OLD_SPACE_SIZE=96 caps the app heap" "$override" '(.body | tonumber) > 90000000 and (.body | tonumber) < 160000000' GET /heap
docker rm -f "$override" >/dev/null

# Node accepts underscores in option names; a heap flag in either spelling, from NODE_OPTIONS or the
# command, must win over the derived one (512 MB would otherwise give about 264 MB).
heap_variants=("underscore NODE_OPTIONS|-e NODE_OPTIONS=--max_old_space_size=96|node /fixture/server.mjs"
    "mixed NODE_OPTIONS|-e NODE_OPTIONS=--max-old_space-size=96|node /fixture/server.mjs"
    "underscore command flag||node --max_old_space_size=96 /fixture/server.mjs")
for variant in "${heap_variants[@]}"; do
    IFS='|' read -r label env_args command <<<"$variant"
    # shellcheck disable=SC2086
    heap_app="$(docker run -d --init --network none --label "$LABEL" --stop-timeout 45 --cpus 2 --memory 512m --read-only \
        --tmpfs /run/nginx-nodejs:uid=1000,gid=1000,mode=0700 --tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
        --tmpfs /var/lib/nginx-nodejs:uid=1000,gid=1000,mode=0700 -v "$fixture:/fixture:ro" \
        -e APP_DIR=/fixture -e STATIC_ROOT=/fixture/.output/public -e NODE_PORT=3007 -e NODE_HEALTH_PATH=/ready \
        $env_args "$IMAGE" $command)"
    check "heap flag ($label): healthcheck passes" wait_healthy "$heap_app"
    expect "heap flag ($label): the user's 96 MB wins over the derived value" "$heap_app" '(.body | tonumber) > 90000000 and (.body | tonumber) < 160000000' GET /heap
    docker rm -f "$heap_app" >/dev/null
done

# NODE_OPTIONS (for example an APM --require) belongs to the app process only: the supervisor, the
# helper Node processes and the image HEALTHCHECK must not load it. marker.cjs logs every process it loads in.
options_app="$(docker run -d --init --network none --label "$LABEL" --stop-timeout 45 "${HARDENED_FLAGS[@]}" \
    --tmpfs /var/lib/nginx-nodejs:uid=1000,gid=1000,mode=0700 --health-interval 2s --health-start-interval 1s \
    -v "$fixture:/fixture:ro" -e APP_DIR=/fixture -e STATIC_ROOT=/fixture/.output/public \
    -e NODE_PORT=3007 -e NODE_HEALTH_PATH=/ready -e LOKI_ENABLED=0 \
    -e INGRESS_TRUSTED_IPS=127.0.0.2 -e 'NODE_OPTIONS=--require /fixture/marker.cjs' \
    "$IMAGE" node /fixture/server.mjs)"
check "NODE_OPTIONS: container becomes healthy through the image HEALTHCHECK" wait_health_status "$options_app"
sleep 3
markers="$(docker exec "$options_app" cat /tmp/markers 2>/dev/null || true)"
check "NODE_OPTIONS: the app process loads it" grep -qx /fixture/server.mjs <<<"$markers"
check "NODE_OPTIONS: no helper or HEALTHCHECK process loads it${markers:+ (loaded by: $(tr '\n' ' ' <<<"$markers"))}" \
    bash -c '! grep -E "/etc/nginx-nodejs/" <<<"$1"' bash "$markers"
expect "NODE_OPTIONS: the app gets the user's value and no internal variable" "$options_app" \
    '.body | fromjson | .options == "--require /fixture/marker.cjs" and .appOptions == null' GET /node-options
# Trusting 127.0.0.2 as ingress lets it name the client with X-Forwarded-For; /__container_health must
# still judge the TCP peer, so a forged 127.0.0.1 from that peer does not open it.
expect "container health route: loopback peer still answers" "$options_app" '.status == 200' GET /__container_health
expect "container health route: trusted ingress peer forging X-Forwarded-For 127.0.0.1 gets 404" "$options_app" \
    '.status == 404' GET /__container_health '{"X-Forwarded-For":"127.0.0.1"}' 127.0.0.2
docker rm -f "$options_app" >/dev/null

# ------------------------------------------------------- config validation
for args in "-e NODE_PORT=8080 $IMAGE" "-e RUNTIME_MODE=staging $IMAGE" "$IMAGE sh -c true" \
    "-e NGINX_WORKER_PROCESSES=0 $IMAGE" "-e NGINX_WORKER_PROCESSES=65 $IMAGE" "-e NGINX_WORKER_PROCESSES=many $IMAGE" \
    "-e NGINX_WORKER_CONNECTIONS=10 $IMAGE" "-e NGINX_WORKER_CONNECTIONS=lots $IMAGE" \
    "-e NODE_MAX_OLD_SPACE_SIZE=huge $IMAGE" "-e NODE_MAX_OLD_SPACE_SIZE=4 $IMAGE"; do
    code=0
    # shellcheck disable=SC2086
    timeout 60 docker run --rm --init --network none --label "$LABEL" $args >/dev/null 2>&1 || code=$?
    check "invalid config exits 78: $args" test "$code" = 78
done

finish
