# nginx-nodejs: rootless Node.js runtime behind Nginx

A rootless Node.js application runtime behind Nginx. It serves static files with Brotli
and gzip, falls back to your Node process, supervises both with s6, and keeps sanitized
logs that can ship to Loki through an optional Fluent Bit collector. Your application code,
framework tooling, assets and deployment CI stay in your own project.

Source and full docs: [github.com/LotusWebAgency/nginx-nodejs](https://github.com/LotusWebAgency/nginx-nodejs).
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
releases arrive with rebuilds and the major never changes under a major tag. Nginx and the
Wolfi base are not pinned either. `latest` moves to a newer major when one is added here, so
production images should name a major (`24`) or, better, a `<major.minor>` tag or digest:

```dockerfile
FROM lotuswebagency/nginx-nodejs:26.12@sha256:...
```

Platform: `linux/amd64`. `linux/arm64` is planned; it is not published until it has been
verified natively. Every published digest carries an SBOM, max-mode SLSA provenance and a
keyless Cosign signature. Tag policy:
[SUPPORT.md](https://github.com/LotusWebAgency/nginx-nodejs/blob/main/SUPPORT.md).

## What is inside

- **Wolfi** base (`cgr.dev/chainguard/wolfi-base`), pinned by digest and verified against
  Chainguard's signature in CI. Node.js 22, 24 or 26 from the Wolfi `nodejs-<major>` package.
- **Nginx** (Wolfi `nginx-mainline`) with the **ngx_brotli** filter and static modules,
  built from a pinned upstream commit, checked by SHA-256, with a local patch for byte
  ranges and `416` responses.
- **s6** supervision with bounded `s6-log` writers.
- **Fluent Bit**, compiled from a pinned upstream tag checked by SHA-256, with only the
  plugins the collector needs, one header patch and hardening flags (stack protector,
  `_FORTIFY_SOURCE=3`, PIE, full RELRO). The Brotli modules get the same flags.
- Busybox without its network applets. Wolfi's busybox has no `wget` or `nc`.
- CA certificates, so Loki over TLS verifies against the system store.

The runtime has no npm and no application dependencies. The `builder` image adds npm to the
same base and runs as the same user.

## Image contract

| Item | Value |
|---|---|
| Entrypoint | `/etc/nginx-nodejs/entrypoint.sh`. It validates the settings, generates the runtime configuration in `/run/nginx-nodejs`, validates Nginx and the collector, then runs `s6-svscan`. |
| Default command | `node /usr/share/nginx-nodejs/demo/server.mjs`, a demo app. Replace it with your own. |
| User | `node`, UID and GID 1000. This includes the Nginx master. The container refuses to start as any other UID. |
| Working directory | `/app`, owned by `node`. |
| Port | `8080/tcp`, Nginx. Node listens on loopback only (`127.0.0.1`, `NODE_PORT`). An internal static server uses loopback `8081`. |
| Healthcheck | Baked: every 10 s, 5 s timeout, 30 s start period, 3 retries. |
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
are required only with a read-only root. `/var/lib/nginx-nodejs` must be writable and should
be a volume: it holds the logs, the collector checkpoints and the Loki queue. Give each
running container its own volume. Bind mounts need permissions that UID 1000 can use.

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

Your application must listen on `HOST` and `PORT` (the image sets `HOST=127.0.0.1` and
`PORT=$NODE_PORT` for the Node child) and return `200` at `NODE_HEALTH_PATH` (default
`/healthz`). If it has no such route, set the variable to a lightweight route such as `/`.

The command is a JSON exec array that starts with `node` or `/usr/bin/node`. It runs as the
supervised Node child without shell evaluation, from `APP_DIR`. `npm start` and shell
command strings are not supported and fail at startup with exit code 78. For development,
copy the dev dependencies into a derived runtime, set `RUNTIME_MODE=dev` and run the
framework's Node CLI directly. `RUNTIME_MODE` changes routing only; set
`NODE_ENV=development` yourself.

The Node child inherits the container environment, so secrets passed as plain environment
variables are visible to your application. The Loki credentials have `*_FILE` variants.

## Configuration

| Variable | Default | Contract |
|---|---|---|
| `APP_DIR` | `/app` | Working directory for the Node child |
| `STATIC_ROOT` | `/app/public` | Nginx static root. May contain dot directories such as `.output` |
| `NODE_PORT` | `3000` | 1024 to 65535, excluding 8080 and 8081 |
| `NODE_HEALTH_PATH` | `/healthz` | Absolute path that must return `200` from Node and from the public listener |
| `RUNTIME_MODE` | `prod` | `prod`: static files first, then Node. `dev`: proxy every request to Node |
| `APP_ENV` | `production` | Loki `environment` label |
| `NODE_ENV` | `production` | Node application environment, independent of routing mode |
| `LOG_SERVICE` | `nginx-nodejs` | Service name in log events, the collector filter and the Loki `service` label |
| `PUBLIC_SCHEME` | `http` | `http` or `https`. Sent to Node as `X-Forwarded-Proto` |
| `INGRESS_TRUSTED_IPS` | empty | Comma-separated IPs or CIDRs of trusted ingress proxies. None are trusted by default |
| `FLUENT_BIT_FILTERS_FILE` | unset | Mounted JSON array of extra collector filters |

`LOG_SERVICE` and `APP_ENV` take 1 to 64 letters, digits, underscores and hyphens, and must
start with a letter or digit. `APP_DIR` and `STATIC_ROOT` must be absolute paths made of
letters, digits and `_ . / -`, with no `..` component. Invalid settings stop the container
with exit code 78.

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
and `Cache-Control` values are reused. WebSocket and other `Upgrade` requests are forwarded
to Node. Request bodies up to 51 MiB are accepted. Nginx waits up to 5 seconds to connect to
Node and 60 seconds for a response.

## Static files and caching

In `prod` mode Nginx serves an existing file or a directory's `index.html` first and falls
back to Node. A path with a short extension (1 to 8 letters or digits) is also tried as a
static file before Node. `/assets/` is static only: a miss is a `404`, never a Node request.

- `/assets/` gets `Cache-Control: public, max-age=31536000, immutable`. Use content-hashed
  file names there.
- Every other static path gets `public, max-age=0`, so clients revalidate. `/images/` is not
  treated as immutable.
- Node responses keep their own `Cache-Control`. A Node response without one gets `no-store`.
- Every `4xx` and `5xx` response gets `no-store`.

Requests are rejected with `404` for any path that has a dot-prefixed segment, or a `dist`,
`src`, `node_modules` or `cache` segment, for source maps (`.map`), and for direct requests
to `.br` and `.gz` files. In `dev` mode the same dot, `src`, `node_modules`, `cache` and
`.map` rules apply, and `/dist` and `/cache` at the root and `dist/server` are blocked too.

Responses of types text, CSS, JavaScript, JSON, XML and SVG of at least 512 bytes are
compressed at request time with Brotli or gzip (level 5). If a `.br` or `.gz` sibling of a
static file exists, it is served as is. The image does not create them; precompress in your
build. Byte ranges and conditional requests (`304`) are answered by the internal static
server, so they work for static files and for precompressed siblings.

## Logs

The pipeline is: application and Nginx output, a sanitizing wrapper, bounded `s6-log` files,
Fluent Bit filters, Loki. Secrets are removed before anything is written to disk.

This is not transparent JSON forwarding. The wrapper keeps only these event names:
`http_request`, `runtime_error`, `browser_error`, `sentry_delivery` and `nginx_request`.
From each it keeps a fixed set of validated fields: `requestId`, `release`, `method`,
`status`, `durationMs`, `durationSeconds`, `kind`, `eventId` and `delivered`. If your
application needs more, change that contract in a derived image. Collector filters cannot
recover a field the wrapper discarded.

Everything else becomes a bounded diagnostic:

- Structured output with an unknown event is replaced by a fixed "unrecognized structured
  output omitted" message. Its values are never copied.
- Unstructured lines are scrubbed (query strings, bearer and basic tokens, URL credentials,
  values next to `token`, `key`, `secret`, `password`, `dsn` or `auth`, email addresses, IP
  addresses, long digit runs) and cut to 512 characters.
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
64 KiB. They run after the mandatory service filter and are bound to the `runtime` tag; any
`match_regex` key is ignored. A malformed file fails startup with exit code 78. Do not put
credentials in it. Rule syntax is in the Fluent Bit documentation for
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
- The Nginx access events travel over loopback UDP and a bounded buffer. Either can drop an
  event under load.
- At start, the collector snapshots the retained archives once the three log writers report
  ready. After a restart, records can be replayed, so duplicates are possible.

This is not lossless delivery.

## Health and shutdown

The healthcheck verifies, in order: the supervisor and its state flags, the Nginx and Node
processes and their parentage, the Nginx event relay, the three ready log writers, a `200`
from `NODE_HEALTH_PATH` on the public listener and on Node, the internal static server, and,
when `LOKI_ENABLED=1`, the Fluent Bit process. External Loki availability is not a health
condition.

If Node or Nginx exits, the container stops with exit code 1. If the collector fails, only
the collector restarts, after 5 seconds. On `SIGTERM` the supervisor stops every service.
Nginx drains connections on `QUIT`. Node and Nginx get 15 seconds before a kill, the
collector 10. Allow 45 seconds in total (`--stop-timeout 45`, `stop_grace_period: 45s`).

## Security and provenance

- Rootless: UID and GID 1000 for every process, no setuid or setgid files in the image.
- A read-only root filesystem, dropped capabilities, `no-new-privileges` and `noexec` tmpfs
  mounts are supported and tested; see Hardened deployment above.
- Pull requests build, test and scan without publishing. A Trivy gate fails the build on any
  fixable CRITICAL or HIGH finding, any finding in CISA's Known Exploited Vulnerabilities
  catalog (fixable or not), and any AGPL license.
- Merging to `main` publishes with an SBOM, max-mode SLSA provenance and a keyless Cosign
  signature. A weekly rebuild (Mondays) picks up new Wolfi packages.

Verify what you pulled:

```sh
# The signing identity is the shared build workflow; the second flag ties it to this repo.
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/vdementev/docker-workflows/\.github/workflows/build-image\.yml@' \
  --certificate-github-workflow-repository LotusWebAgency/nginx-nodejs \
  lotuswebagency/nginx-nodejs:latest
```

Trivy reads the APK database, so it does not see Fluent Bit and ngx_brotli, which are
compiled from source. Their versions are recorded in the image labels
`com.lotuswebagency.fluent-bit.version` and `com.lotuswebagency.ngx-brotli.commit`. Reporting, scope and boundaries:
[SECURITY.md](https://github.com/LotusWebAgency/nginx-nodejs/blob/main/SECURITY.md).

## Tests

`tests.sh` gates every pull request, for the runtime image and for the builder. Every probe
container runs with `--network none`, and requests are made from inside the container. It
covers: rootless UID 1000 and no setuid or setgid files, the full healthcheck, the demo
route and a static file, a custom command line and port, caching headers, Brotli and gzip
and precompressed siblings, byte ranges and `304`, blocked paths, forged `X-Forwarded-For`,
security headers, secret canaries absent from persisted logs, Loki delivery with bearer
authentication against a mock server, the hardened run flags (read-only root, no capabilities, `noexec` tmpfs) and restart
without tmpfs, absent busybox network applets, binary hardening of Fluent Bit and the Brotli
modules,
supervision when the Node child exits, and exit code 78 for invalid settings. The full list is
in the [README](https://github.com/LotusWebAgency/nginx-nodejs#tests).

Not covered by automated tests: Loki over TLS or with basic authentication against a real
server, and `linux/arm64`.

## Related images

| Image | Role |
|---|---|
| [`dementev/angie`](https://hub.docker.com/r/dementev/angie) | Reverse proxy and TLS terminator |
| [`dementev/nginx`](https://hub.docker.com/r/dementev/nginx) | Static sites and SPAs behind that proxy |
| [`lotuswebagency/php`](https://hub.docker.com/r/lotuswebagency/php) | PHP 7.0 to 8.5 compiled from source with PGO, hardened |
| **[`lotuswebagency/nginx-nodejs`](https://hub.docker.com/r/lotuswebagency/nginx-nodejs)** (this image) | Rootless Node.js runtime behind Nginx with sanitized logs and optional Loki delivery |
| [`dementev/mysql-percona`](https://hub.docker.com/r/dementev/mysql-percona) | Percona Server for MySQL 8.4 LTS |
| [`dementev/adminer`](https://hub.docker.com/r/dementev/adminer) | Adminer 6 with every supported driver |

## Maintainer

Built and maintained by [Vasilii Dementev](https://vasiliidementev.com) at
[Lotus Web Agency](https://lotuswebagency.com). Issues and pull requests:
[github.com/LotusWebAgency/nginx-nodejs](https://github.com/LotusWebAgency/nginx-nodejs).

Packaging in this repository is MIT licensed. Node.js, Nginx, ngx_brotli, s6, Fluent Bit and
the other bundled software keep their own upstream licenses.
