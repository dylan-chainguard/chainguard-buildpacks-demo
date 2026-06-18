# Buildpacks Demo

A minimal end-to-end example of using [Cloud Native Buildpacks](https://buildpacks.io) (in 3 ways) to containerize a Node.js application.

## Run the demo

Build all of the images using `pack` and run vulnerability scans using `grype`.

```
./scripts/demo.sh

...

Image                             Critical        High      Medium         Low  Negligible     Unknown       Total
------------------------------------------------------------------------------------------------------------------
Heroku stock                             0           0        1019         149          39           0        1207
Custom buildpack                         1          24        1027         154          39           0        1245
Chainguard base                          0           0           1           0           0           0           1
```

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
pack config default-builder heroku/builder:24
```

`heroku/builder:24` is multi-arch (amd64 + arm64), so it builds natively
on both Intel/AMD and Apple Silicon hosts. 
`paketobuildpacks/builder-jammy-base` is amd64-only — using it on an arm64
Mac forces Docker into Rosetta/qemu translation, which can fail at runtime
with errors.

---

## Option 1 — Build with a stock builder

Paketo's Node.js buildpack is bundled in the default builder, so no custom
buildpack is required to get an image:

```sh
pack build example-demo-app:paketo \
  --path ./app \
  --builder heroku/builder:24
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
pack build example-demo-app:custom-buildpack \
  --path ./app \
  --builder heroku/builder:24 \
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

The default `heroku/builder:24` run image (`heroku/heroku:24`) is full
Ubuntu Noble. Swapping it for `cgr.dev/chainguard/node` gives a distroless,
Wolfi-based final image with a much smaller attack surface.

### How the swap works

The buildpack lifecycle takes *two* images: a **build image** (where
detect/build run) and a **run image** (the base of the final app image). We
keep the Heroku builder for the build phase and only swap the run image.

A bare `cgr.dev/chainguard/node` is missing CNB metadata, so the lifecycle
won't accept it. The following labels can be added via Chainguard's [Custom Assembly](https://edu.chainguard.dev/chainguard/chainguard-images/features/ca-docs/custom-assembly/) feature. Alternatively, they can be added using a Dockerfile. `run-image/Dockerfile` wraps it with the labels the spec
requires:

| Label                                | Purpose                                                              |
| ------------------------------------ | -------------------------------------------------------------------- |
| `io.buildpacks.base.id`              | Target ID of the run image (Platform API ≥ 0.12).                    |
| `io.buildpacks.base.distro.name`     | OS distro identifier (`wolfi`).                                      |
| `io.buildpacks.base.distro.version`  | OS distro version.                                                   |
| `io.buildpacks.rebasable`            | Declares ABI compatibility across versions — needed for `pack rebase`.|
| `io.buildpacks.stack.id`             | `heroku-24` - Legacy stack ID — must equal the build image's. Pre-0.12 lifecycles still match on this. |

The base image's existing `User=65532` is preserved (and differs from the
Heroku build image's user at UID 1000, which the spec requires).

### Build it

```sh
docker build -t example/run-chainguard-node:latest ./run-image

pack build example-demo-app:chainguard \
  --path ./app \
  --builder heroku/builder:24 \
  --buildpack ./buildpack \
  --run-image example/run-chainguard-node:latest
```

### Build it with a Custom Assembly image

```
# add the labels listed above as annotations
chainctl image repo build edit --parent your-org --repo node --save-as node-buildpack

...

Image configuration changes:
Legend: + to add, ~ to change, - to remove

annotations (+8, ~0, -0, final: 8):
  + io.buildpacks.base.description = "Chainguard distroless Node.js wrapped as a CNB run image"
  + io.buildpacks.base.distro.name = "wolfi"
  + io.buildpacks.base.distro.version = "latest"
  + io.buildpacks.base.homepage = "https://images.chainguard.dev/directory/image/node/overview"
  + io.buildpacks.base.id = "com.example.chainguard.node"
  + io.buildpacks.base.maintainer = "example"
  + io.buildpacks.rebasable = "true"
  + io.buildpacks.stack.id = "heroku-24"

...

pack build example-demo-app:chainguard \
  --path ./app \
  --builder heroku/builder:24 \
  --buildpack ./buildpack \
  --run-image cgr.dev/your-org/node-buildpack:latest
```

### A note on the Node.js binary used

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
field, defaulting to `server.js`). This works on both the Heroku and
Chainguard run images.

### Verify it's actually Chainguard underneath

```sh
docker image inspect example-demo-app:chainguard \
  --format '{{ index .Config.Labels "io.buildpacks.base.distro.name" }}'
# wolfi
```

### Additional Notes

- **File ownership across UID boundary.** The build phase chowns app files
  to the build image's user (UID 1000 for both Heroku and Paketo builders).
  The Chainguard run image runs as 65532. Read-only workloads (like this
  demo) are fine because exported layers default to `0644`. Apps that write
  to their own bundled files may hit `EACCES` — fix by writing only to
  `/tmp` or a writable volume.
- **Native modules use the build-time Node ABI.** Even with
  `BP_NODE_FROM_BASE=true`, `npm install` runs during the build phase
  against the buildpack's downloaded Node.js (currently 20.11.1), so any
  native modules in `node_modules/` are compiled against that ABI. They'll
  only load cleanly on a base whose Node major version matches. For this
  pure-JS demo it doesn't matter; for apps with native deps, pin
  `engines.node` in `package.json` to match the version shipped in
  `cgr.dev/chainguard/node` (check with
  `docker run --rm cgr.dev/chainguard/node --version`).
- **Stack-id.** The wrapper declares
  `io.buildpacks.stack.id=heroku-24` even though the OS is Wolfi. This
  satisfies pre-0.12 lifecycle stack matching against the Heroku builder;
  newer lifecycles use `io.buildpacks.base.*` and ignore the stack label.
  If you switch to a different builder, update this label to match
  (e.g. `io.buildpacks.stacks.jammy` for Paketo Jammy).

---

## Vulnerability Comparisons

```
$ ./scripts/scan.sh
scanning example-demo-app:paketo...
scanning example-demo-app:custom-buildpack...
scanning example-demo-app:chainguard...

Image                             Critical        High      Medium         Low  Negligible     Unknown       Total
------------------------------------------------------------------------------------------------------------------
Heroku stock                             0           0        1019         149          39           0        1207
Custom buildpack                         1          24        1027         154          39           0        1245
Chainguard base                          0           0           1           0           0           0           1
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
