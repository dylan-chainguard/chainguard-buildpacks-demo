#!/usr/bin/env bash
set -euo pipefail

# Scans the three demo images with grype and prints a per-severity table.
# Assumes all three images are already built locally (see README Options 1-3).
#
# Requires: docker, grype, jq.

IMAGES=(
  "Heroku stock|example-demo-app:paketo"
  "Custom buildpack|example-demo-app:custom-buildpack"
  "Chainguard base|example-demo-app:chainguard"
)

SEVERITIES=(Critical High Medium Low Negligible Unknown)

for cmd in docker grype jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required tool: $cmd" >&2; exit 1; }
done

# Phase 1: scan everything, collect formatted rows.
rows=()
for entry in "${IMAGES[@]}"; do
  label="${entry%%|*}"
  image="${entry##*|}"

  if ! docker image inspect "$image" >/dev/null 2>&1; then
    rows+=("$(printf '%-30s%84s' "$label" "(image $image not found locally)")")
    continue
  fi

  echo "scanning ${image}..." >&2
  json="$(grype "$image" -o json -q 2>/dev/null)"

  row="$(printf '%-30s' "$label")"
  total=0
  for sev in "${SEVERITIES[@]}"; do
    count=$(jq --arg s "$sev" '[.matches[] | select(.vulnerability.severity == $s)] | length' <<<"$json")
    row+="$(printf '%12s' "$count")"
    total=$((total + count))
  done
  row+="$(printf '%12s' "$total")"
  rows+=("$row")
done


echo ""
# Phase 2: print the table all at once.
printf "%-30s" "Image"
for sev in "${SEVERITIES[@]}"; do
  printf "%12s" "$sev"
done
printf "%12s\n" "Total"
printf -- '-%.0s' $(seq 1 114); echo

for row in "${rows[@]}"; do
  echo "$row"
done
