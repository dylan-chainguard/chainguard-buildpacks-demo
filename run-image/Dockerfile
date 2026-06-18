# Wraps the Chainguard distroless Node.js image with the labels a Cloud Native
# Buildpacks lifecycle needs to use it as a "run image" (the base layer the
# exporter writes app layers on top of).
#
# The base is distroless: no shell, no npm, no package manager. The CNB
# launcher is a static Go binary written into a layer by the exporter, so it
# runs fine without a shell — but it means our buildpack's `launch.toml` must
# invoke `node` directly (not `npm start`, which is a shell script).
#
# Inherited from cgr.dev/chainguard/node:latest:
#   User       = 65532  (differs from Paketo build image's cnb UID 1000 — required by spec)
#   WorkingDir = /app
#   PATH       = /usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin
#   Entrypoint = /usr/bin/node    (overridden by the lifecycle exporter to /cnb/process/web)

FROM cgr.dev/chainguard/node:latest

# Modern Platform API (>= 0.12) target/distro labels.
LABEL io.buildpacks.base.id="com.example.chainguard.node" \
      io.buildpacks.base.distro.name="wolfi" \
      io.buildpacks.base.distro.version="latest" \
      io.buildpacks.base.maintainer="Example" \
      io.buildpacks.base.homepage="https://images.chainguard.dev/directory/image/node/overview" \
      io.buildpacks.base.description="Chainguard distroless Node.js wrapped as a CNB run image" \
      io.buildpacks.rebasable="true"

# Legacy stack id — must match the build image's stack so the lifecycle's
# pre-0.12 stack-matching check passes. paketobuildpacks/builder-jammy-base
# declares io.buildpacks.stacks.jammy.
LABEL io.buildpacks.stack.id="io.buildpacks.stacks.jammy"
