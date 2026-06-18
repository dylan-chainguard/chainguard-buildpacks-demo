#!/usr/bin/env bash
set -euo pipefail

# End-to-end demo: tool check -> build all three images -> scan them.
# Run from anywhere; the script anchors itself to the repo root.

cd "$(dirname "$0")/.."

BUILDER="heroku/builder:24"
RUN_IMAGE="example/run-chainguard-node:latest"

# 1. Tool check
for cmd in docker pack grype jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required tool: $cmd" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable" >&2; exit 1; }

# 2. Builds
echo "=== Option 1: Heroku stock ==="
pack build example-demo-app:paketo \
  --path ./app \
  --builder "${BUILDER}"

echo
echo "=== Option 2: Custom buildpack ==="
pack build example-demo-app:custom-buildpack \
  --path ./app \
  --builder "${BUILDER}" \
  --buildpack ./buildpack

echo
echo "=== Option 3: Chainguard base ==="
docker build -t "${RUN_IMAGE}" ./run-image
pack build example-demo-app:chainguard \
  --path ./app \
  --builder "${BUILDER}" \
  --buildpack ./buildpack \
  --run-image "${RUN_IMAGE}"

# 3. Scan
echo
echo "=== Scan ==="
./scripts/scan.sh
