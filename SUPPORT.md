# Support and lifecycle

Image: [`lotuswebagency/nginx-nodejs`](https://hub.docker.com/r/lotuswebagency/nginx-nodejs).
Platform: `linux/amd64`. Usage and configuration are in [README.md](README.md).

## Tags

| Tag | Contents |
|---|---|
| `latest` | The runtime image. Moves on every merge to `main` and on the weekly rebuild. |
| `26.12.1` | The runtime image with that exact Node.js version (an example). Republished in place, with a new digest and the same tag, while that version is current. |
| `26.12` | The newest patch release of that Node.js minor. |
| `builder` | The build-stage image with Node.js and npm. |
| `26.12.1-builder`, `26.12-builder` | The same version tags for the builder. |

Version tags are read out of the built image (`node -p process.versions.node`) after the
tests and the Trivy gate. A tag cannot claim a version the image does not run.

## What "supported" means

A tag is supported while it is being rebuilt. `latest`, `builder` and the version tags of
the Node release currently in Wolfi are rebuilt weekly (Mondays, about 04:40 UTC) and on
every merge to `main`. Once Wolfi's `nodejs` package moves to a newer release, the tags of
the old release stop moving. They stay pullable but get no further rebuilds or CVE fixes.

There is no long-term support line and no security patch deadline. The image follows
Wolfi's current Node.js, whatever its release status.

## Floating packages

The Wolfi base, Node.js, npm, Nginx and s6 are unversioned. A rebuild takes whatever Wolfi
currently ships, so `latest` can change Node major version without a change in this
repository. Nothing publishes unless `tests.sh` and the Trivy gate pass first, but that is a
check on the new build, not a promise of compatibility with your application.

To stay on one Node major, pin the `<major.minor>` tag. To get the exact bytes you tested,
pin the digest:

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
`/app`, `/run/nginx-nodejs` and `/var/lib/nginx-nodejs`, port 8080, UID 1000, the
log event names and fields, and the exit codes. Changes to them are called out in the pull
request and covered by `tests.sh`.

## Getting help

Open an issue at
[github.com/LotusWebAgency/nginx-nodejs/issues](https://github.com/LotusWebAgency/nginx-nodejs/issues).
Security reports go through [SECURITY.md](SECURITY.md) instead.
