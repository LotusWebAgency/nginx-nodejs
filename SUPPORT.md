# Support and lifecycle

Image: [`lotuswebagency/nginx-nodejs`](https://hub.docker.com/r/lotuswebagency/nginx-nodejs).
Platform: `linux/amd64`. Usage and configuration are in [README.md](README.md).

## Tags

Pick a Node.js major with the tag. `latest` and `builder` are the newest major (26).

| Tag | Contents |
|---|---|
| `latest`, `26` | The runtime image on Node.js 26. Moves on every merge to `main` and on the weekly rebuild. |
| `24`, `22` | The runtime image on that Node.js major. |
| `26.12.1`, `26.12` | The runtime image with that exact Node.js version (an example), republished in place, with a new digest and the same tag, while that version is current; or the newest patch release of that minor. The same forms exist for 24 and 22. |
| `builder`, `26-builder` | The build-stage image on Node.js 26, with Node.js and npm. |
| `24-builder`, `22-builder` | The builder on that Node.js major. |
| `26.12.1-builder`, `26.12-builder` | The version tags for the builder (examples). |

Version tags are read out of the built image (`node -p process.versions.node`) after the
tests and the Trivy gate. A tag cannot claim a version the image does not run.

## Node.js majors

| Node.js | Status in October 2026 | Upstream end of life |
|---|---|---|
| 22 | Maintenance LTS | 2027-04-30 |
| 24 | Maintenance LTS (since 2026-10-20) | 2028-04-30 |
| 26 | Active LTS (since 2026-10-28) | 2029-04-30 |

Dates are from the [Node.js release schedule](https://github.com/nodejs/Release/blob/main/schedule.json).
The image does not extend them: plan to move to a newer major before the end-of-life date of
the one you run.

Each major is built from the matching Wolfi `nodejs-<major>` package. A major tag never
changes major version; only its minor and patch releases move. `latest` and `builder` move
to a newer major when one is added to this repository, so name a major in production.

## What "supported" means

A tag is supported while it is being rebuilt. `latest`, `builder`, the major tags and the
version tags of the Node releases currently in Wolfi are rebuilt weekly (Mondays, about
04:40 UTC) and on every merge to `main`. Once Wolfi's `nodejs-<major>` package moves to a
newer minor, the tags of the old minor stop moving. If Wolfi drops a major, its tags stop
being rebuilt. They stay pullable but get no further rebuilds or CVE fixes.

There is no long-term support line and no security patch deadline beyond that. Each major
follows Wolfi's current package for it, whatever its upstream release status.

## Floating packages

The Wolfi base, Node.js (within the chosen major), npm, Nginx and s6 are unversioned. A
rebuild takes whatever Wolfi currently ships, so a tag can change minor or patch version
without a change in this repository. Nothing publishes unless `tests.sh` and the Trivy gate
pass first, but that is a check on the new build, not a promise of compatibility with your
application.

To stay on one Node.js minor, pin the `<major.minor>` tag. To get the exact bytes you
tested, pin the digest:

```dockerfile
FROM lotuswebagency/nginx-nodejs:26.12@sha256:...
```

## Built from source

Two components are compiled in the Dockerfile rather than installed from a package:

- **Fluent Bit** is built from the upstream tag that matches the version the Wolfi
  `fluent-bit` package selects, with only the plugins the collector needs. One header
  include is added to `src/flb_http_client.c` during the build. Wolfi's own patches are not
  inherited. The patch needs review when upstream changes that file.
- **ngx_brotli** is built from a pinned upstream commit, verified by SHA-256, against the
  Nginx source package that matches the installed Nginx. A local patch
  ([`docker/ngx_brotli-ranges.patch`](docker/ngx_brotli-ranges.patch)) enables byte ranges
  on precompressed files and clears the content encoding on `416` responses. The build fails
  if the patch no longer applies.

## Platforms

Only `linux/amd64` is built, tested and published. `linux/arm64` is planned. It will be
published after it has been verified natively, because compiling Fluent Bit under QEMU is
too slow for the gate. No date is committed.

## Patch cadence

| Trigger | What happens |
|---|---|
| Pull request | Build, `tests.sh`, Trivy gate. Nothing is published. |
| Merge to `main` | The same, then publish, SBOM, provenance, Cosign signature, and the Docker Hub description sync. |
| Weekly rebuild | The same pipeline with no source change, to pick up new Wolfi packages. |
| Fixable CRITICAL or HIGH finding | The build fails and nothing is published until it is fixed or accepted with a reason in `.trivyignore`. |

## What is tested

`tests.sh` gates every pull request, for the runtime image and for the builder. The list of
checks is in the [README](README.md#tests).

Not covered by automated tests, and so not claimed as verified:

- Loki over TLS and with basic authentication against a real server. Delivery with bearer
  authentication and labels is tested against a mock server.
- `linux/arm64`.

## Breaking changes

These are public interface: the environment variables in the
[README](README.md#configuration) and [Send to Loki](README.md#send-to-loki), the paths
`/app`, `/run/nginx-nodejs` and `/var/lib/nginx-nodejs`, ports 8080 and 8081, UID 1000, the
log event names and fields, and the exit codes. Changes to them are called out in the pull
request and covered by `tests.sh`.

## Getting help

Open an issue at
[github.com/LotusWebAgency/nginx-nodejs/issues](https://github.com/LotusWebAgency/nginx-nodejs/issues).
Security reports go through [SECURITY.md](SECURITY.md) instead.
