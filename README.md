# nginx-nodejs

A rootless Node.js application runtime behind Nginx. It serves static files with
Brotli and gzip, falls back to your Node process, supervises both with s6, and keeps
sanitized logs that can ship to Loki through an optional Fluent Bit collector. Your
application code, framework tooling, assets and deployment CI stay in your own project.

Docker Hub: [`lotuswebagency/nginx-nodejs`](https://hub.docker.com/r/lotuswebagency/nginx-nodejs).
Source: [github.com/LotusWebAgency/nginx-nodejs](https://github.com/LotusWebAgency/nginx-nodejs).
Built on Wolfi, like [`lotuswebagency/php`](https://hub.docker.com/r/lotuswebagency/php).

```dockerfile
FROM lotuswebagency/nginx-nodejs:builder AS build
COPY --chown=node:node package.json package-lock.json ./
RUN npm ci
COPY --chown=node:node . ./
RUN npm run build

FROM lotuswebagency/nginx-nodejs
COPY --from=build --chown=node:node /app/dist/ /app/dist/
ENV STATIC_ROOT=/app/dist/client
CMD ["node", "dist/server/entry.mjs"]
```

A full consumer Dockerfile is in [Use your application](#use-your-application).

## Tags

Pick a Node.js major with the tag. `latest` and `builder` are the newest major (26).

| Tag | Contents |
|---|---|
| `latest`, `26` | The runtime image on Node.js 26. Moves on every merge to `main` and on the weekly rebuild. |
| `24`, `22` | The runtime image on that Node.js major. |
| `26.12.1`, `26.12` | The runtime image with that exact Node.js version, or the newest patch of that minor (examples; the tags follow the Node in the image). The same forms exist for 24 and 22. |
| `builder`, `26-builder` | The build-stage image on Node.js 26: Node.js and npm, no Nginx. |
| `24-builder`, `22-builder` | The builder on that Node.js major. |
| `26.12.1-builder`, `26.12-builder` | The version tags for the builder (examples). |

Use the same major for both stages, so you build and run on the same Node.js:

```dockerfile
FROM lotuswebagency/nginx-nodejs:24-builder AS build
# ... install and build ...

FROM lotuswebagency/nginx-nodejs:24
```

| Node.js | Status in October 2026 | Upstream end of life |
|---|---|---|
| 22 | Maintenance LTS | 2027-04-30 |
| 24 | Maintenance LTS (since 2026-10-20) | 2028-04-30 |
| 26 | Active LTS (since 2026-10-28) | 2029-04-30 |

Dates are from the [Node.js release schedule](https://github.com/nodejs/Release/blob/main/schedule.json).

Version tags are read out of the built image (`node -p process.versions.node`) after the
tests and the Trivy gate, never from the Dockerfile, so a tag cannot claim a Node version
the image does not run.

Each major tag follows the matching Wolfi `nodejs-<major>` package, so minor and patch
releases arrive with rebuilds and the major never changes under a major tag. Nginx floats
(`apk upgrade` runs on every rebuild); the Wolfi base is pinned by digest, which Renovate
refreshes after CI verifies Chainguard's signature. `latest` moves to a newer major when one is added here, so
production images should name a major (`24`) or, better, a `<major.minor>` tag or digest:

```dockerfile
FROM lotuswebagency/nginx-nodejs:26.12@sha256:...
```

Platform: `linux/amd64`. `linux/arm64` is planned; it is not published until it has been
verified natively. Every published digest carries an SBOM, max-mode SLSA provenance and a
keyless Cosign signature. See [Security and provenance](#security-and-provenance).

## What is inside

- **Wolfi** base (`cgr.dev/chainguard/wolfi-base`), pinned by digest in the Dockerfile and
  refreshed by Renovate after CI verifies its Chainguard signature. Node.js 22, 24 or 26 comes
  from the Wolfi `nodejs-<major>` package; `apk upgrade` runs on every rebuild.
- **Nginx** (Wolfi `nginx-mainline`) with the **ngx_brotli** filter and static modules.
  ngx_brotli is built from a pinned upstream commit, checked by SHA-256, against the
  installed Nginx source, with a local patch for byte ranges and `416` responses
  ([`docker/ngx_brotli-ranges.patch`](docker/ngx_brotli-ranges.patch)). The
  **headers-more** module (pinned the same way) sets the security and cache headers, so a
  `416` from the range filter carries each header once.
- **s6** supervision with bounded `s6-log` writers.
- **Fluent Bit**, compiled from a pinned upstream tag (`FLUENT_BIT_VERSION`, source tarball
  checked by `FLUENT_BIT_SHA256` in the Dockerfile), with only the plugins the collector needs
  (tail, grep, modify, record_modifier, Loki and null outputs, JSON and YAML, TLS, SQLite,
  disk backlog) and one header patch. It is built with stack protector, `_FORTIFY_SOURCE=3`,
  stack-clash protection, PIE, full RELRO and (on amd64) `-fcf-protection`. The Nginx
  modules get the same flags.
- Busybox with its network applet links removed (`ping`, `netstat`, `traceroute`, ...);
  Wolfi's busybox has no `wget` or `nc`. The busybox binary still contains the applets and
  Node itself can open sockets, so this is defense in depth, not a boundary.
- CA certificates, so Loki over TLS verifies against the system store.

The runtime has no npm and no application dependencies. Compilers stay in intermediate
build stages. The `builder` image adds npm to the same base and runs as the same user.

## Image contract

| Item | Value |
|---|---|
| Entrypoint | `/etc/nginx-nodejs/entrypoint.sh`. It validates the settings, generates the runtime configuration in `/run/nginx-nodejs`, validates Nginx and the collector, then runs `s6-svscan`. |
| Default command | `node /usr/share/nginx-nodejs/demo/server.mjs`, a demo app. Replace it with your own. |
| User | `node`, UID and GID 1000. This includes the Nginx master. The container refuses to start as any other UID. |
| Working directory | `/app`, owned by `node`. |
| Port | `8080/tcp`, Nginx. Node listens on loopback only (`127.0.0.1`, `NODE_PORT`). |
| Healthcheck | Baked: `node /etc/nginx-nodejs/healthcheck.mjs`, every 10 s (every 1 s during the 30 s start period), 5 s timeout, 3 retries; healthy a few seconds after start. |
| Stop signal | `SIGTERM`. Allow 45 seconds. |
| Exit codes | `78` for invalid configuration, printed as `Runtime configuration error: ...` on stderr. `1` when the Node or Nginx child exits. |
| Logs | Application and Nginx output goes through a sanitizing wrapper into `/var/lib/nginx-nodejs/logs/{node,nginx,nginx-error}/current`, not to `docker logs`. |
| Writable paths | `/run/nginx-nodejs`, `/tmp`, `/var/lib/nginx-nodejs`, and whatever your application writes. |
| Pinning | Tags move with Node releases and weekly rebuilds. Pin `@sha256:...` for reproducible deploys. |

## Quick start

The image ships a demo app so you can see it work:

```sh
docker run -d --init --name nginx-nodejs-demo --read-only \
  --stop-timeout 45 \
  --tmpfs /run/nginx-nodejs:uid=1000,gid=1000,mode=0700 \
  --tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
  -v nginx-nodejs-logs:/var/lib/nginx-nodejs \
  -p 127.0.0.1:8080:8080 lotuswebagency/nginx-nodejs
```

Open `http://localhost:8080/`. `/healthz` is answered by the demo Node server and
`/demo.txt` is a static file from the static root.

The same setup as a compose service, for your own image, behind an ingress proxy that
terminates TLS:

```yaml
services:
  app:
    image: registry.example.com/my-app:latest   # built FROM lotuswebagency/nginx-nodejs
    init: true
    read_only: true
    stop_grace_period: 45s
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      PUBLIC_SCHEME: https
      INGRESS_TRUSTED_IPS: 172.18.0.0/16
    tmpfs:
      - /run/nginx-nodejs:uid=1000,gid=1000,mode=0700
      - /tmp:uid=1000,gid=1000,mode=1777
    volumes:
      - app-logs:/var/lib/nginx-nodejs

volumes:
  app-logs:
```

The container clears stale runtime state in `/run/nginx-nodejs` on start, so
`docker restart` and `restart: unless-stopped` work without a tmpfs. The two tmpfs mounts
are required only with a read-only root. `/var/lib/nginx-nodejs` must be writable and
should be a volume: it holds the logs, the collector checkpoints and the Loki queue. Give
each running container its own volume. Bind mounts need permissions that UID 1000 can use.
Application caches need their own writable mounts.

Put an ingress proxy in front for external TLS. Do not expose port 8080 directly.

### Hardened deployment

The image runs with all of this applied. `tests.sh` starts its fixture container with exactly
these flags, so every release proves it. Nothing in the image needs a capability, a writable
root or an executable tmpfs.

```sh
docker run -d --init --name nginx-nodejs-demo \
  --stop-timeout 45 \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 256 \
  --tmpfs /run/nginx-nodejs:noexec,nosuid,nodev,uid=1000,gid=1000,mode=0700 \
  --tmpfs /tmp:noexec,nosuid,nodev,uid=1000,gid=1000,mode=1777 \
  -v nginx-nodejs-logs:/var/lib/nginx-nodejs \
  -p 127.0.0.1:8080:8080 lotuswebagency/nginx-nodejs
```

The compose equivalent:

```yaml
services:
  app:
    image: registry.example.com/my-app:latest
    init: true
    read_only: true
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    pids_limit: 256
    stop_grace_period: 45s
    tmpfs:
      - /run/nginx-nodejs:noexec,nosuid,nodev,uid=1000,gid=1000,mode=0700
      - /tmp:noexec,nosuid,nodev,uid=1000,gid=1000,mode=1777
    volumes:
      - app-logs:/var/lib/nginx-nodejs
```

On Kubernetes, with `emptyDir` standing in for the tmpfs mounts (an `emptyDir` cannot be
mounted `noexec`; the image does not execute anything from either path):

```yaml
spec:
  terminationGracePeriodSeconds: 45
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: registry.example.com/my-app:latest
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      volumeMounts:
        - { name: run, mountPath: /run/nginx-nodejs }
        - { name: tmp, mountPath: /tmp }
        - { name: state, mountPath: /var/lib/nginx-nodejs }
  volumes:
    - { name: run, emptyDir: { medium: Memory } }
    - { name: tmp, emptyDir: { medium: Memory } }
    - { name: state, emptyDir: {} }
```

Use a persistent volume for `state` if the Loki queue must survive a pod restart. Your
application may need more writable mounts for its own caches.

## Use your application

```dockerfile
FROM lotuswebagency/nginx-nodejs:builder AS build
COPY --chown=node:node package.json package-lock.json ./
RUN npm ci
COPY --chown=node:node . ./
RUN npm run build
RUN npm prune --omit=dev

FROM lotuswebagency/nginx-nodejs
COPY --from=build --chown=node:node /app/dist/ /app/dist/
COPY --from=build --chown=node:node /app/node_modules/ /app/node_modules/
COPY --from=build --chown=node:node /app/package.json /app/package.json
ENV STATIC_ROOT=/app/dist/client
CMD ["node", "dist/server/entry.mjs"]
```

Adapt the output paths and build steps to your framework. The image does not run your
build, install dependencies, generate assets or prune your runtime closure.

Your application must:

- listen on `HOST` and `PORT`. The image sets `HOST=127.0.0.1` and `PORT=$NODE_PORT` for
  the Node child.
- return `200` at `NODE_HEALTH_PATH` (default `/healthz`). If your application has no such
  route, set the variable to a lightweight route such as `/`.

The command is a JSON exec array that starts with `node` or `/usr/bin/node`. It runs as the
supervised Node child without shell evaluation, from `APP_DIR`. `npm start` and shell
command strings are not supported and fail at startup with exit code 78. For development,
copy the dev dependencies into a derived runtime, set `RUNTIME_MODE=dev` and run the
framework's Node CLI directly. Install and bootstrap steps belong to your Dockerfile.
`RUNTIME_MODE` changes routing only; set `NODE_ENV=development` yourself.

The Node child inherits the container environment. Secrets passed as plain environment
variables are visible to your application. See [Send to Loki](#send-to-loki) for the
`*_FILE` variants.

## Configuration

| Variable | Default | Contract |
|---|---|---|
| `APP_DIR` | `/app` | Working directory for the Node child |
| `STATIC_ROOT` | `/app/public` | Nginx static root. May contain dot directories such as `.output` |
| `NODE_PORT` | `3000` | 1024 to 65535, excluding 8080 |
| `NODE_HEALTH_PATH` | `/healthz` | Absolute path that must return `200` from Node and from the public listener |
| `RUNTIME_MODE` | `prod` | `prod`: static files first, then Node. `dev`: proxy every request to Node |
| `APP_ENV` | `production` | Loki `environment` label |
| `NODE_ENV` | `production` | Node application environment, independent of routing mode |
| `LOG_SERVICE` | `nginx-nodejs` | Service name in log events, the collector filter and the Loki `service` label |
| `PUBLIC_SCHEME` | `http` | `http` or `https`. Sent to Node as `X-Forwarded-Proto` |
| `INGRESS_TRUSTED_IPS` | empty | Comma-separated IPs or CIDRs of trusted ingress proxies. None are trusted by default |
| `NGINX_WORKER_PROCESSES` | from the CPU limit | Integer 1 to 64, or `auto`. Unset: `ceil(quota / period)` from cgroup v2 `cpu.max` (so `--cpus 1.5` gives 2), capped at the CPUs the container may use; with no quota, all of them |
| `NGINX_WORKER_CONNECTIONS` | `4096` | Integer 64 to 65535. `worker_rlimit_nofile` is set to twice this plus 256, within the hard limit |
| `NODE_MAX_OLD_SPACE_SIZE` | derived | Integer MB (at least 16) or `off`. Sets `--max-old-space-size` for the application only. Unset: with a cgroup v2 memory limit, (limit - 160 MB) x 0.75, where 160 MB is the allowance for Nginx and the helper processes (floor 64 MB; 512 MB gives 264 MB); with no limit, V8's default. Skipped when `NODE_OPTIONS` (any spelling, such as `--max_old_space_size`) or the command already sets the flag |
| `FLUENT_BIT_FILTERS_FILE` | unset | Mounted JSON array of extra collector filters, see [Logs](#logs) |

`LOG_SERVICE` and `APP_ENV` take 1 to 64 letters, digits, underscores and hyphens, and
must start with a letter or digit. `APP_DIR` and `STATIC_ROOT` must be absolute paths made of
letters, digits and `_ . / -`, with no `..` component. Loki variables are listed under
[Send to Loki](#send-to-loki).

Runtime configuration is generated in `/run/nginx-nodejs` at every start. To change the
Nginx, proxy or route templates, edit the files under `/etc/nginx-nodejs` in a derived
image, not the generated copies.

Nginx replaces the forwarded headers it sends to Node. `X-Forwarded-For` is the client
address Nginx sees: the TCP peer, or, for peers in `INGRESS_TRUSTED_IPS`, the address the
ingress put in `X-Forwarded-For`. A client cannot forge it. `X-Forwarded-Proto` is
`PUBLIC_SCHEME`. Node should trust only its local Nginx proxy.

Your application's CSP, Permissions-Policy and HSTS headers pass through. The image sets
`X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`,
`Referrer-Policy: strict-origin-when-cross-origin`, `X-Request-ID` and `Cache-Control` on
every response. If Node sends any of those five, Nginx replaces it; Node's `X-Request-ID`
and `Cache-Control` values are reused. WebSocket and other `Upgrade` requests are
forwarded to Node. Request bodies up to 51 MiB are accepted. Nginx waits up to 5 seconds to connect to Node
and 60 seconds for a response.

Nginx keeps up to 32 idle connections per worker open to Node and reuses them, closing
an idle one after 4 seconds. Node's default `server.keepAliveTimeout` is 5 seconds; if your
application lowers it below 4 seconds (or sets it to 0), raise it, or the occasional
request may hit a connection Node is closing and fail with `502`. Frameworks that set a
longer timeout need no change.

On start, Nginx runs one worker per CPU of the container's quota (`NGINX_WORKER_PROCESSES`
overrides), and the application's V8 heap is capped below the container memory limit
(`NODE_MAX_OLD_SPACE_SIZE` overrides). `UV_THREADPOOL_SIZE` is left at Node's default of 4;
set it yourself for applications that do heavy file, crypto or DNS work.

## Static files and caching

In `prod` mode Nginx serves an existing file or a directory's `index.html` first and falls
back to Node. A path with a short extension (1 to 8 letters or digits) is also tried as a
static file before Node. `/assets/` is static only: a miss is a `404`, never a Node
request.

- `/assets/` gets `Cache-Control: public, max-age=31536000, immutable`. Use content-hashed
  file names there.
- Every other static path gets `public, max-age=0`, so clients revalidate. `/images/` is
  not treated as immutable.
- Node responses keep their own `Cache-Control`. A Node response without one gets
  `no-store`.
- Every `4xx` and `5xx` response gets `no-store`.

Requests are rejected with `404` for any path that has a dot-prefixed segment, or a
`dist`, `src`, `node_modules` or `cache` segment, for source maps (`.map`), and for direct
requests to `.br` and `.gz` files. In `dev` mode the same dot, `src`, `node_modules`,
`cache` and `.map` rules apply, and `/dist` and `/cache` at the root and `dist/server`
are blocked too.

Responses of types text, CSS, JavaScript, JSON, XML and SVG of at least 512 bytes are
compressed at request time with Brotli (level 4) or gzip (level 5). **Precompress your
assets for production**: if a `.br` or `.gz` sibling of a static file exists, it is served
as is, with no CPU cost per request, and at a higher compression ratio than request-time
compression allows. The image does not create them; run `brotli -k -q 11` and
`gzip -k -9` (or your bundler's compression plugin) over the static root in your build.
Nginx serves static files directly on port 8080, with an `open_file_cache` (10 s
revalidation, so a file created or replaced at runtime appears within about 10 s).
Conditional requests (`304`) work everywhere. Byte ranges work for files that are not
compressed at request time: precompressed siblings (ranges address the encoded bytes) and
types outside the compressible list, such as video, audio, PDF and archives. A range request for a compressible
text file with no sibling is answered with the full compressed response (`200`), which
HTTP allows. Multi-range requests get the full file (`max_ranges 1`). Proxied Node responses
are never range-processed by Nginx. Symlinks under the static root are followed only when
link and target have the same owner (`disable_symlinks if_not_owner`); a link to anything
else answers `404` and logs a `crit` line. Consumer
policies belong in `routes.prod.conf`, `routes.dev.conf`, `proxy.conf` and `nginx.conf`
under `/etc/nginx-nodejs`.

## Logs

The pipeline is: application and Nginx output, a sanitizing wrapper, bounded `s6-log`
files, Fluent Bit filters, Loki. Secrets are removed before anything is written to disk.

This is not transparent JSON forwarding. The wrapper keeps only these event names:
`http_request`, `runtime_error`, `browser_error`, `sentry_delivery` and `nginx_request`.
From each it keeps a fixed set of validated fields: `requestId`, `release`, `method`,
`status`, `durationMs`, `durationSeconds`, `kind`, `eventId` and `delivered`. The allowlist is
in [`docker/process.mjs`](docker/process.mjs) and the redaction rules are in
[`docker/scrub.mjs`](docker/scrub.mjs). If your application needs more fields or events,
change that contract in a derived image. Collector filters cannot recover a field the
wrapper discarded.

Everything else becomes a bounded diagnostic:

- Structured output with an unknown event is replaced by a fixed "unrecognized structured
  output omitted" message. Its values are never copied.
- Unstructured lines are scrubbed (query strings, bearer and basic tokens, URL
  credentials, values next to `token`, `key`, `secret`, `password`, `dsn` or `auth`, email
  addresses, IP addresses, long digit runs) and cut to 512 characters.
- A quoted credential assignment discards the rest of the line, including incomplete JSON
  fragments.
- Each process emits at most 30 diagnostics per minute. Lines over 16 KiB are omitted.

Nginx access events carry only the request ID, method, status and duration. They never
include the URL, client address or headers.

Redaction is a bounded heuristic. It does not make arbitrary application output safe to log.
Do not log credentials or sensitive request data.

Each stream (`node`, `nginx`, `nginx-error`) rotates at about 1 MB and keeps up to three
archives, 3 MB at most.

To add enrichment or rename fields, mount a JSON file and set
`FLUENT_BIT_FILTERS_FILE=/config/log-filters.json`:

```json
[
  {"name":"modify","add":"application example","rename":"durationMs duration_ms"},
  {"name":"record_modifier","remove_key":["release"]}
]
```

Only `grep`, `modify` and `record_modifier` filters are accepted, in a file of at most
64 KiB. They run after the mandatory service filter and are bound to the `runtime` tag;
any `match_regex` key is ignored. A malformed file fails startup with exit code 78. Do not
put credentials in it. Rule syntax is in the Fluent Bit documentation for
[modify](https://docs.fluentbit.io/manual/data-pipeline/filters/modify) and
[record_modifier](https://docs.fluentbit.io/manual/data-pipeline/filters/record-modifier).

## Send to Loki

Delivery is off by default. Local log rotation runs either way.

| Variable | Default | Contract |
|---|---|---|
| `LOKI_ENABLED` | `0` | `1` turns the collector on |
| `LOKI_HOST` | none | Required when enabled. Host name or IPv4 address, no scheme and no port |
| `LOKI_PORT` | `3100` | 1 to 65535 |
| `LOKI_TLS` | `off` | `on` for HTTPS. Certificate and host name checks stay on |
| `LOKI_CA_FILE` | system store | Path to a mounted CA bundle for a private CA |
| `LOKI_BEARER_TOKEN` | unset | Bearer authentication |
| `LOKI_USER`, `LOKI_PASSWORD` | unset | Basic authentication. Set both |
| `LOKI_TENANT_ID` | unset | Optional `X-Scope-OrgID` tenant |

Bearer and basic authentication are mutually exclusive. `LOKI_BEARER_TOKEN`, `LOKI_USER`,
`LOKI_PASSWORD` and `LOKI_TENANT_ID` each have a `*_FILE` variant that reads a mounted
secret file (up to 8 KiB, trailing newline removed). Set the value or the file, not both.
Prefer the file: a plain environment variable is also visible to your Node process. The
generated collector configuration and credential file are mode `0600`, and a credential that
contains `${...}` is passed literally.

Labels are `service=$LOG_SERVICE` and `environment=$APP_ENV`. Request and release IDs stay
JSON fields in the log line, not labels.

Delivery is bounded and best effort:

- Fluent Bit keeps checkpoints and a 256 MiB disk queue under `/var/lib/nginx-nodejs`.
  Retries back off up to 30 seconds. When the queue is full, the oldest chunks are evicted.
- The Nginx access events travel over loopback UDP and a bounded buffer. Either can drop
  an event under load.
- At start, the collector snapshots the retained archives once the three log writers
  report ready. After a restart, records can be replayed, so duplicates are possible.

This is not lossless delivery.

## Health and shutdown

The healthcheck verifies, in order: the supervisor and its state flags, the Nginx and
Node processes and their parentage, the Nginx event relay, the three ready log writers,
a `200` from `NODE_HEALTH_PATH` on the public listener and on Node, a `200` from the
loopback-only `/__container_health` route, and, when `LOKI_ENABLED=1`, the Fluent Bit
process. External Loki availability is not a health condition.

If Node or Nginx exits, the container stops with exit code 1. If the collector fails, only
the collector restarts, after 5 seconds. On `SIGTERM` the supervisor stops every service.
Nginx drains connections on `QUIT`. Node and Nginx get 15 seconds before a kill, the
collector 10. Allow 45 seconds in total (`--stop-timeout 45`, `stop_grace_period: 45s`).

## Security and provenance

- Rootless: UID and GID 1000 for every process, no setuid or setgid files in the image.
- A read-only root filesystem, dropped capabilities, `no-new-privileges` and `noexec`
  tmpfs mounts are supported and tested; see [Hardened deployment](#hardened-deployment).
- The compiled components (Fluent Bit, the Nginx modules) are checked for PIE (executables),
  no text relocations (modules), full RELRO, a non-executable stack and stack protector.
  Fortification is observed where a binary imports `__*_chk` calls; the tests cannot tell
  `_FORTIFY_SOURCE` levels apart.
- `NODE_OPTIONS` reaches only your app process, not the supervisor, the helpers or the
  HEALTHCHECK. `/__container_health` answers only the loopback TCP peer, whatever
  `X-Forwarded-For` says.
- Pull requests build, test and scan without publishing. A Trivy gate fails the build on
  any fixable CRITICAL or HIGH finding, any finding in CISA's Known Exploited
  Vulnerabilities catalog (fixable or not), and any AGPL license.
- The pinned Wolfi base digest must carry Chainguard's keyless signature before CI builds on it.
- Merging to `main` publishes with an SBOM, max-mode SLSA provenance and a keyless
  Cosign signature.

Verify what you pulled:

```sh
# The signing identity is the shared build workflow; the second flag ties it to this repo.
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/LotusWebAgency/docker-workflows/\.github/workflows/build-image\.yml@' \
  --certificate-github-workflow-repository LotusWebAgency/nginx-nodejs \
  lotuswebagency/nginx-nodejs:latest
```

Trivy reads the APK database, so it does not see Fluent Bit, ngx_brotli and headers-more,
which are compiled from source. Their versions are recorded in the image labels
`com.lotuswebagency.fluent-bit.version`, `com.lotuswebagency.ngx-brotli.commit` and
`com.lotuswebagency.headers-more.commit`, and pinned in the Dockerfile. Reporting, scope and boundaries: [SECURITY.md](SECURITY.md).

## CI

`.github/workflows/ci.yml` is a thin caller of the shared reusable workflow in
[`LotusWebAgency/docker-workflows`](https://github.com/LotusWebAgency/docker-workflows), pinned to
`@v1`, with a matrix of three Node.js majors (22, 24, 26) by two targets (`runtime`, `builder`):
six builds, each tested with `NODE_MAJOR` set so the image must run that major.

1. A `verify-base` job checks the Cosign signature of the pinned Wolfi digest. Then pull
   requests build `linux/amd64`, run `tests.sh` against the built image, then the Trivy
   vulnerability, KEV and license gates. Nothing is published.
2. Merging to `main` publishes the major tags (`22`, `24`, `26`, `22-builder`, ...), `latest`
   and `builder` (Node.js 26) and the version tags, with the SBOM,
   provenance and Cosign signature, and syncs [DOCKERHUB.md](DOCKERHUB.md) to the Docker Hub
   description.
3. A weekly rebuild (Mondays) republishes the current tags to pick up new Wolfi packages.

## Tests

`tests.sh` gates every pull request. `IMAGE=<ref> ./tests.sh` tests the runtime image and
`IMAGE=<ref> TARGET=builder ./tests.sh` tests the builder. Every probe container runs with
`--network none`, and requests are made from inside the container.

Runtime checks:

- Rootless UID 1000 and no setuid or setgid files.
- The full healthcheck passes.
- The demo Node route and a static file.
- A custom command line, `NODE_PORT`, `NODE_HEALTH_PATH` and `STATIC_ROOT`.
- Immutable `/assets/` against revalidating static files, and `no-store` for uncached and
  error responses.
- Runtime Brotli and gzip, and precompressed `.gz` and `.br` siblings.
- Byte ranges (including on both siblings and the plain `416`), multi-range requests
  answered whole, and conditional `304`.
- Each security header and `Cache-Control` exactly once on static `200`, `206`, `416`, `404`
  and on proxied `200` and `500`.
- Symlinks under the static root: out-of-tree targets answer `404`, same-owner links are served
  (skipped when the tests run as root).
- `NODE_OPTIONS` loaded by the app only, heap flags in underscore and mixed spellings, and
  `/__container_health` refusing a forged `X-Forwarded-For` from a trusted ingress peer.
- WebSocket upgrade, upstream connection reuse, and a range request that falls back to Node.
- CPU and memory limits: `--cpus 2` gives 2 Nginx workers, `--memory 512m` caps the app
  heap, and the `NGINX_WORKER_PROCESSES` and `NODE_MAX_OLD_SPACE_SIZE` overrides apply.
- Invalid `NGINX_*` and `NODE_MAX_OLD_SPACE_SIZE` values exit 78.
- Blocked dot, source, source map and sidecar paths.
- A forged `X-Forwarded-For` is replaced, and `PUBLIC_SCHEME` is forwarded.
- Security headers.
- Secret canaries are absent from the persisted logs.
- Loki delivery with bearer authentication and the expected labels, against a mock server
  inside the container.
- A fixture container with the full [hardened flags](#hardened-deployment) (read-only root,
  no capabilities, `no-new-privileges`, PID limit, `noexec` tmpfs mounts), and a restart
  without tmpfs.
- `wget`, `nc` and the other busybox network applets are absent.
- Fluent Bit and the three Nginx modules: PIE (executables), no text relocations (modules),
  full RELRO, non-executable stack, stack protector, fortification where `__*_chk` is
  imported and, on amd64, the IBT note. These read the binaries with the host's `readelf`.
- A Node child that exits stops the container with exit code 1.
- An invalid `NODE_PORT` or a command that does not start with `node` exits with 78.

Builder checks: Node and npm present, UID 1000, no Nginx. With `NODE_MAJOR` set, both
targets also assert that the image runs that Node.js major.

Not covered by the automated tests: Loki over TLS or with basic authentication against a
real server, and `linux/arm64`. Startup does validate the generated collector
configuration with `fluent-bit --dry-run`.

## Build locally

You need Docker Engine with Buildx, and binutils (`readelf`) on the host for the binary
checks in `tests.sh`. Building compiles Fluent Bit and the Nginx modules
and downloads their sources from GitHub.

```sh
docker buildx build --load --network host --target runtime -t nginx-nodejs:local .
docker buildx build --load --network host --target builder -t nginx-nodejs:builder .

IMAGE=nginx-nodejs:local ./tests.sh
IMAGE=nginx-nodejs:builder TARGET=builder ./tests.sh
```

The default is Node.js 26. Choose another major with the `NODE_MAJOR` build argument
(`22`, `24` or `26`), and set the same variable for the tests to assert it:

```sh
docker buildx build --load --network host --build-arg NODE_MAJOR=24 --target runtime -t nginx-nodejs:node24 .
IMAGE=nginx-nodejs:node24 NODE_MAJOR=24 ./tests.sh
```

A repeat build reuses cached package stages. Add `--no-cache` to pull fresh Wolfi
packages.

## Related images

| Image | Role |
|---|---|
| [`dementev/angie`](https://hub.docker.com/r/dementev/angie) | Reverse proxy and TLS terminator |
| [`dementev/nginx`](https://hub.docker.com/r/dementev/nginx) | Static sites and SPAs behind that proxy |
| [`lotuswebagency/php`](https://hub.docker.com/r/lotuswebagency/php) | PHP 7.0 to 8.5 compiled from source with PGO, hardened |
| **[`lotuswebagency/nginx-nodejs`](https://hub.docker.com/r/lotuswebagency/nginx-nodejs)** (this image) | Rootless Node.js runtime behind Nginx with sanitized logs and optional Loki delivery |
| [`dementev/mysql-percona`](https://hub.docker.com/r/dementev/mysql-percona) | Percona Server for MySQL 8.4 LTS |
| [`dementev/adminer`](https://hub.docker.com/r/dementev/adminer) | Adminer 6 with every supported driver |

## Maintainer and license

Built and maintained by [Vasilii Dementev](https://vasiliidementev.com) at
[Lotus Web Agency](https://lotuswebagency.com). Issues and pull requests:
[github.com/LotusWebAgency/nginx-nodejs](https://github.com/LotusWebAgency/nginx-nodejs).
Security reports: [SECURITY.md](SECURITY.md). Tag lifecycle and rebuild cadence:
[SUPPORT.md](SUPPORT.md).

Packaging in this repository is MIT licensed, see [LICENSE](LICENSE). Node.js, Nginx,
ngx_brotli, headers-more, s6, Fluent Bit and the other bundled software keep their own upstream licenses.
