# Buildpacks Demo

A minimal end-to-end example of using [Cloud Native Buildpacks](https://buildpacks.io)
to containerize a Node.js application — including a hand-rolled Node.js buildpack.

## Layout

```
.
├── app/                      # Sample Node.js webserver
│   ├── package.json
│   ├── project.toml          # CNB project descriptor (build excludes, metadata)
│   └── server.js
├── buildpack/                # Custom Node.js buildpack
│   ├── buildpack.toml        # Buildpack metadata (API 0.10)
│   └── bin/
│       ├── detect            # Decides whether the buildpack participates
│       └── build             # Installs Node.js + deps, writes launch.toml
├── run-image/                # CNB run-image wrapper around Chainguard node
│   └── Dockerfile
└── README.md
```

## The sample app

`app/server.js` is a small Express server exposing a handful of dummy endpoints:

| Method | Path             | Description                       |
| ------ | ---------------- | --------------------------------- |
| GET    | `/`              | Service info + endpoint listing   |
| GET    | `/health`        | Liveness probe                    |
| GET    | `/api/users`     | List dummy users                  |
| GET    | `/api/users/:id` | Fetch a single dummy user         |
| POST   | `/api/echo`      | Echo the JSON body back to caller |

It honors `PORT` (defaults to `8080`), which is what the buildpack-produced
launcher will set at runtime.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (running)
- [`pack`](https://buildpacks.io/docs/for-platform-operators/how-to/integrate-ci/pack/) CLI

Install `pack` on macOS:

```sh
brew install buildpacks/tap/pack
```

Verify:

```sh
pack version
docker info >/dev/null && echo "docker ok"
```

Set a default builder once so you don't need `--builder` every time:

```sh
pack config default-builder paketobuildpacks/builder-jammy-base
```

---

## Option 1 — Build with a stock builder (fastest path)

Paketo's Node.js buildpack is bundled in the default builder, so no custom
buildpack is required to get an image:

```sh
pack build example-demo-app:paketo \
  --path ./app \
  --builder paketobuildpacks/builder-jammy-base
```

Run it:

```sh
docker run --rm -p 8080:8080 example-demo-app:paketo
curl localhost:8080/api/users
```

---

## Option 2 — Build with the custom buildpack

Use the buildpack in this repo directly from its source directory. `pack`
packages it on the fly:

```sh
pack build example-demo-app:example \
  --path ./app \
  --builder paketobuildpacks/builder-jammy-base \
  --buildpack ./buildpack
```

What the custom buildpack does, in order:

1. **detect** — looks for `package.json` in the app root; opts out (exit 100)
   if missing.
2. **build**
   - Resolves the Node.js version from `engines.node` (if pinned to an exact
     `X.Y.Z`) or falls back to the default in `buildpack.toml`.
   - Downloads the matching Node.js tarball into a cached layer marked
     `build = true, launch = true, cache = true`.
   - Symlinks `node_modules` into its own cached layer, then runs
     `npm ci --omit=dev` (or `npm install --omit=dev` if no lockfile).
   - Writes `launch.toml` declaring a default `web` process: `npm start`.

Run it:

```sh
docker run --rm -p 8080:8080 example-demo-app:example
```

Inspect the image's process types and buildpack metadata:

```sh
pack inspect example-demo-app:example
```

---

## Option 3 — Build on a Chainguard base image

The default Paketo run image (`paketobuildpacks/run-jammy-base`) is full
Ubuntu Jammy. Swapping it for `cgr.dev/chainguard/node` gives a distroless,
Wolfi-based final image with a much smaller attack surface.

### How the swap works

The buildpack lifecycle takes *two* images: a **build image** (where
detect/build run) and a **run image** (the base of the final app image). We
keep the Paketo Jammy builder for the build phase and only swap the run image.

A bare `cgr.dev/chainguard/node` is missing CNB metadata, so the lifecycle
won't accept it. `run-image/Dockerfile` wraps it with the labels the spec
requires:

| Label                                | Purpose                                                              |
| ------------------------------------ | -------------------------------------------------------------------- |
| `io.buildpacks.base.id`              | Target ID of the run image (Platform API ≥ 0.12).                    |
| `io.buildpacks.base.distro.name`     | OS distro identifier (`wolfi`).                                      |
| `io.buildpacks.base.distro.version`  | OS distro version.                                                   |
| `io.buildpacks.rebasable`            | Declares ABI compatibility across versions — needed for `pack rebase`.|
| `io.buildpacks.stack.id`             | Legacy stack ID — must equal the build image's. Pre-0.12 lifecycles still match on this. |

The base image's existing `User=65532` is preserved (and differs from the
Paketo build image's `cnb` user at UID 1000, which the spec requires).

### Build it

```sh
docker build -t example/run-chainguard-node:latest ./run-image

pack build example-demo-app:chainguard \
  --path ./app \
  --builder paketobuildpacks/builder-jammy-base \
  --buildpack ./buildpack \
  --run-image example/run-chainguard-node:latest
```

### Sourcing Node.js from the base (no env flag needed)

Without intervention, the buildpack's downloaded Node.js layer would be
prepended to `PATH` at launch and shadow the Chainguard image's
`/usr/bin/node` — you'd ship two Node binaries and run the wrong one.

The buildpack autodetects this case via `CNB_TARGET_DISTRO_NAME`. The
lifecycle sets that env var from the run image's `io.buildpacks.base.distro.name`
label (Platform API ≥ 0.10), and our `run-image/Dockerfile` declares
`wolfi`. When the buildpack sees `wolfi`, it marks its Node.js layer as
build-only (`launch = false`), so the binary is used for `npm install`
but never carried into the final image.

You'll see this line in the build log:

```
---> Node.js will be sourced from the run image at launch (autodetect (CNB_TARGET_DISTRO_NAME=wolfi))
```

To override the autodetect:

| Setting                       | Behavior                                                        |
| ----------------------------- | --------------------------------------------------------------- |
| (unset)                       | Autodetect: `wolfi` → use base, else install into launch layer. |
| `BP_NODE_FROM_BASE=true`      | Always use the base's Node; never carry our copy at launch.     |
| `BP_NODE_FROM_BASE=false`     | Always install our Node into the launch layer.                  |

The heuristic is conservative — it's a label check, not a filesystem
probe (the build phase never sees the run image's contents). If you
point `--run-image` at a Wolfi base that *doesn't* ship Node (e.g. bare
`cgr.dev/chainguard/wolfi-base`), pass `BP_NODE_FROM_BASE=false` to
restore the launch-layer install.

Run + verify:

```sh
docker run --rm -p 8080:8080 example-demo-app:chainguard
curl -s localhost:8080/ | jq
```

### Why `node`, not `npm start`

`cgr.dev/chainguard/node` is distroless — no shell. The official `npm`
binary is a `#!/bin/sh` wrapper script, so launching it on a shell-less
image fails. `buildpack/bin/build` writes a `launch.toml` that invokes
`node <main>` directly (resolving `<main>` from `package.json`'s `main`
field, defaulting to `server.js`). This works on both the Paketo and
Chainguard run images.

### Verify it's actually Chainguard underneath

```sh
pack inspect example-demo-app:chainguard | grep -i 'run image'
docker image inspect example-demo-app:chainguard \
  --format '{{ index .Config.Labels "io.buildpacks.base.distro.name" }}'
# wolfi
```

### Caveats

- **File ownership across UID boundary.** The build phase chowns app files
  to UID 1000 (Paketo cnb). The Chainguard run image runs as 65532. Read-only
  workloads (like this demo) are fine because exported layers default to
  `0644`. Apps that write to their own bundled files may hit `EACCES` —
  fix by writing only to `/tmp` or a writable volume.
- **Native modules use the build-time Node ABI.** Even with
  `BP_NODE_FROM_BASE=true`, `npm install` runs during the build phase
  against the buildpack's downloaded Node.js (currently 20.11.1), so any
  native modules in `node_modules/` are compiled against that ABI. They'll
  only load cleanly on a base whose Node major version matches. For this
  pure-JS demo it doesn't matter; for apps with native deps, pin
  `engines.node` in `package.json` to match the version shipped in
  `cgr.dev/chainguard/node` (check with
  `docker run --rm cgr.dev/chainguard/node --version`).
- **Stack-id "white lie".** The wrapper declares
  `io.buildpacks.stack.id=io.buildpacks.stacks.jammy` even though the OS is
  Wolfi. This satisfies pre-0.12 lifecycle stack matching; newer lifecycles
  use `io.buildpacks.base.*` and ignore the stack label.

---

## Rebuild speed

Because both `nodejs` and `node_modules` layers are marked `cache = true`,
subsequent builds skip the Node.js download and reuse `node_modules` when
`package-lock.json` is unchanged:

```sh
pack build example-demo-app:example --path ./app --buildpack ./buildpack
# ... 'Reusing cached layer' for nodejs + node_modules
```

## Verifying the running container

```sh
docker run -d --name demo -p 8080:8080 example-demo-app:example
curl -s localhost:8080/ | jq
curl -s localhost:8080/health | jq
curl -s -X POST localhost:8080/api/echo \
  -H 'content-type: application/json' \
  -d '{"hello":"world"}' | jq
docker rm -f demo
```

## Pinning a different Node.js version

Edit `app/package.json` and pin an exact version:

```json
"engines": { "node": "20.11.1" }
```

Anything that isn't an exact `X.Y.Z` (e.g. `>=20`, `^20.11`) is ignored and
the buildpack default in `buildpack/buildpack.toml` is used instead.

## Troubleshooting

- **`ERROR: failed to build: executing lifecycle: ... no buildpack groups passed detection`**
  The custom buildpack opted out — confirm `app/package.json` exists and that
  you passed `--path ./app`.
- **`exec format error` when running the container on Apple Silicon**
  The buildpack downloads `linux-arm64` when built on `aarch64`. If you're
  cross-building, pass `--platform linux/amd64` to both `pack build` and
  `docker run`.
- **Slow first build**
  Expected — the builder image and Node.js tarball are pulled once and then
  cached.
