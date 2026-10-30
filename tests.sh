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
# JSON: {status, headers, body, decoded}. Args: container method path [headers-json].
read -r -d '' PROBE <<'JS' || true
const http = require('node:http');
const zlib = require('node:zlib');
const [method, path, headers = '{}'] = process.argv.slice(1);
const request = http.request({ host: '127.0.0.1', port: 8080, method, path, headers: JSON.parse(headers), timeout: 5000 }, response => {
  const chunks = [];
  response.on('data', chunk => chunks.push(chunk));
  response.on('end', () => {
    const raw = Buffer.concat(chunks);
    const encoding = response.headers['content-encoding'];
    const decoded = encoding === 'br' ? zlib.brotliDecompressSync(raw) : encoding === 'gzip' ? zlib.gunzipSync(raw) : raw;
    console.log(JSON.stringify({ status: response.statusCode, headers: response.headers, body: raw.toString('utf8'), decoded: decoded.toString('utf8') }));
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
# expect <name> <container> <jq-filter> <method> <path> [headers-json]
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
exit_code() {
    timeout 60 docker wait "$1"
}

# ------------------------------------------------------------------ demo app
demo="$(docker run -d --init --network none --label "$LABEL" --stop-timeout 45 "$IMAGE")"
check "demo: healthcheck passes" wait_healthy "$demo"
check "runs as UID/GID 1000" sh -c "[ \"\$(docker exec $demo id -u):\$(docker exec $demo id -g)\" = 1000:1000 ]"
[ -z "$NODE_MAJOR" ] || check "node is major $NODE_MAJOR" node_major_is
check "no setuid/setgid files" sh -c "[ -z \"\$(docker exec $demo find / -xdev -perm /6000 -type f)\" ]"
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
printf '<svg xmlns="http://www.w3.org/2000/svg">%s</svg>\n' "$(printf '<rect width="1" height="1"/>%.0s' $(seq 1 40))" > "$public/images/logo.svg"
printf 'license text\n' > "$public/LICENSE"
printf '<!doctype html><title>docs</title>\n' > "$public/docs/index.html"
printf '{}\n' > "$public/assets/app.0123abcd.js.map"
printf 'SECRET=1\n' > "$public/.env"
printf 'module.exports = 1;\n' > "$public/node_modules/pkg/index.js"
cat > "$fixture/server.mjs" <<'JS'
import { createServer } from 'node:http';

const port = Number(process.env.PORT);
createServer((request, response) => {
  switch (request.url) {
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
}).listen(port, process.env.HOST);
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
app="$(docker run -d --init --network none --label "$LABEL" --stop-timeout 45 --read-only \
    --tmpfs /run/nginx-nodejs:uid=1000,gid=1000,mode=0700 \
    --tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
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
check "read-only root: healthcheck passes with collector enabled" wait_healthy "$app"

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

# ------------------------------------------------------- config validation
for args in "-e NODE_PORT=8080 $IMAGE" "-e RUNTIME_MODE=staging $IMAGE" "$IMAGE sh -c true"; do
    code=0
    # shellcheck disable=SC2086
    timeout 60 docker run --rm --init --network none --label "$LABEL" $args >/dev/null 2>&1 || code=$?
    check "invalid config exits 78: $args" test "$code" = 78
done

finish
