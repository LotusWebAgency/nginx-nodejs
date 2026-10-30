# Security policy

## Reporting a vulnerability

Report privately, not in a public issue, to `security@lotuswebagency.com`.

Useful in a report: the tag or digest, the CVE or a reproduction, and what an attacker gets.
If you have a fix, a pull request is welcome, but send the report first.

No response-time guarantee is made. A fix ships as a rebuild of the current tags, so
`docker pull` is the upgrade path. Tag lifecycle and rebuild cadence: [SUPPORT.md](SUPPORT.md).

## What is automated

Every build (pull request, merge to `main`, weekly rebuild) runs the shared pipeline in
[LotusWebAgency/docker-workflows](https://github.com/LotusWebAgency/docker-workflows):

- `tests.sh` runs against the built image. Publishing waits for it.
- A Trivy scan fails the build on any fixable CRITICAL or HIGH finding before an image can
  be published. Two further gates fail on any finding in CISA's Known Exploited
  Vulnerabilities catalog, fixable or not, and on AGPL-licensed packages.
- Before the build, a `verify-base` job checks the Cosign signature of the pinned Wolfi base
  digest against Chainguard's release workflow identity. Findings accepted rather than fixed would be recorded in a root
  `.trivyignore` with a reason; the repository has none today.
- Pull requests build, test and scan without publishing. Only a merge to `main` publishes.
- Published digests carry an SBOM, max-mode SLSA provenance and a keyless Cosign signature.

Verify what you pulled:

```sh
# The signing identity is the shared build workflow; the second flag ties it to this repo.
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/LotusWebAgency/docker-workflows/\.github/workflows/build-image\.yml@' \
  --certificate-github-workflow-repository LotusWebAgency/nginx-nodejs \
  lotuswebagency/nginx-nodejs:latest
```

The Wolfi base is pinned by digest and refreshed by Renovate. The weekly rebuild runs
`apk upgrade` and picks up new Wolfi packages. Node.js and Nginx float with the Wolfi
packages, so a rebuild can bring a new Node version. Pin a `<major.minor>` tag or a digest if you need
a fixed one.

## Controls in the image

- Every process runs as UID and GID 1000, including the Nginx master. The container refuses
  to start as any other UID. The tests check that the image has no setuid or setgid files.
- A read-only root filesystem is supported. Mount tmpfs at `/run/nginx-nodejs` and `/tmp`,
  and keep `/var/lib/nginx-nodejs` on a separate volume. The tests also run with all
  capabilities dropped, `no-new-privileges`, a PID limit and `noexec,nosuid,nodev` tmpfs
  mounts. [Hardened deployment](README.md#hardened-deployment) has the Docker, compose and
  Kubernetes settings.
- Fluent Bit and the Nginx modules (Brotli, headers-more) are compiled with stack protector,
  `_FORTIFY_SOURCE=3`, stack-clash protection and full RELRO (Fluent Bit also as PIE, and
  `-fcf-protection` on amd64). The tests check the produced binaries; they cannot tell
  fortify levels apart, and observe fortification only where a binary imports `__*_chk` calls.
- Busybox network applet links (`ping`, `netstat`, `traceroute` and similar) are removed; Wolfi's
  busybox has no `wget` or `nc`. The binary still contains the applets and Node can open
  sockets itself, so this is defense in depth, not a boundary.
- Node listens on loopback only.
- Static serving follows symlinks only when link and target have the same owner, answers
  multi-range requests with the full file, and `NODE_OPTIONS` is kept away from the
  supervisor, helpers and HEALTHCHECK. `/__container_health` checks the TCP peer, not
  `X-Forwarded-For`.
  Port 8080 is the one public listener, meant to sit behind an ingress proxy that
  terminates TLS.
- Nginx replaces `X-Forwarded-For` and `X-Forwarded-Proto` before Node sees them. Client
  addresses are taken from `X-Forwarded-For` only for peers listed in
  `INGRESS_TRUSTED_IPS`, which is empty by default.
- Dot paths, source and dependency directories, source maps and direct `.br` and `.gz`
  requests return `404`.
- Log fields are allowlisted before they reach disk. Unrecognized JSON is omitted, not
  copied. The tests check that secret canaries do not appear in the persisted logs.
- Loki certificate and host name verification are always on. Generated collector
  configuration and credential files are mode `0600`.

## Boundaries

- **Log redaction is a heuristic.** It removes known patterns from unstructured output and
  allowlists structured fields. It cannot make arbitrary application output safe. Do not
  log credentials or sensitive request data.
- **Environment variables reach your application.** The Node child inherits the container
  environment. Use the `*_FILE` variants for Loki credentials and mount the files read-only.
  Never bake credentials into the image or a filter file.
- **Trivy does not see everything.** It reads the APK database. Fluent Bit, ngx_brotli
  and headers-more are compiled from source and are not in it, so neither the SBOM nor the
  vulnerability scan covers them. All are pinned in the Dockerfile (`FLUENT_BIT_VERSION` and
  `FLUENT_BIT_SHA256`, `NGX_BROTLI_COMMIT` and `NGX_BROTLI_SHA256`, `HEADERS_MORE_COMMIT`
  and `HEADERS_MORE_SHA256`) and recorded in the image labels
  `com.lotuswebagency.fluent-bit.version`, `com.lotuswebagency.ngx-brotli.commit` and
  `com.lotuswebagency.headers-more.commit`.
  Check those against upstream advisories yourself.
- **Not covered by automated tests:** Loki over TLS and with basic authentication against a
  real server, and `linux/arm64`. Delivery with bearer authentication is tested against a
  mock server. These paths are implemented and validated at startup, but treat them as
  unproven until you have tried them against your own Loki.
- **Loki delivery is not lossless.** The queue is bounded and the oldest chunks are evicted
  when it is full. Events can also be dropped on the local UDP relay.

## Scope

In scope: anything shipped from this repository and anything in a published
`lotuswebagency/nginx-nodejs` image.

Out of scope:

- Vulnerabilities in upstream projects that are only packaged here (Node.js, Nginx,
  ngx_brotli, headers-more, s6, Fluent Bit, Wolfi packages). Report those upstream, and tell us so we can
  pin or patch around them.
- Findings that need an already-compromised host or Docker daemon.
- Your own application's code, dependencies and logging.
- Exposing port 8080 directly to the internet. The image is built to run behind an ingress
  proxy.
