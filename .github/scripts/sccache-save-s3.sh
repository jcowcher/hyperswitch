#! /usr/bin/env bash

set -euo pipefail

if [[ "${CI:-false}" != "true" && "${GITHUB_ACTIONS:-false}" != "true" ]]; then
  echo "This script is to be run in a GitHub Actions runner only. Exiting."
  exit 1
fi

if [ -z "${1:-}" ]; then
  echo "::error::Usage: $(basename "$0") <cache-name> [pr-number]"
  exit 1
fi
cache_name="$1"
pr_number="${2:-}"

human() { numfmt --to=iec --suffix=B -- "$1" 2>/dev/null || printf '%s bytes' "$1"; }

# PR-scoped when a PR number is given, so concurrent PRs don't clobber each
# other's — or the shared merge_group/main — cache.
key="sccache-cache/${cache_name}-${RUNNER_OS}-${RUNNER_ARCH}${pr_number:+-pr${pr_number}}.tar"
s3_key="${CACHE_S3_KEY_PREFIX}${key}"
echo "Saving sccache cache, key: ${key}"

# The archive is written out in full before it is uploaded, rather than piped
# straight into `aws s3 cp`, so the pack and the transfer stay separately
# measurable — in a pipe the faster stage just blocks on the slower one. The
# cost is peak disk (archive alongside the cache tree) and the lost overlap.
stage_dir="$(dirname "${SCCACHE_DIR}")"
archive="${stage_dir}/.sccache-save-$$.tar"
trap 'rm -f "${archive}"' EXIT

tree_bytes="$(du -sb "${SCCACHE_DIR}" | cut -f1)"
avail_bytes="$(df -PB1 "${stage_dir}" | awk 'NR == 2 { print $4 }')"
echo "  on disk:     $(human "${tree_bytes}")  (staging area: $(human "${avail_bytes}") free)"
if [ "${avail_bytes}" -lt "${tree_bytes}" ]; then
  echo "::warning::Less free space than the cache tree occupies; the save may run out of space"
fi

# Phase 1 — pack only. Deliberately uncompressed: sccache already
# zstd-compresses its cache entries, so gzip measured 1.02x here while costing
# more wall time than the transfer it was shrinking.
t0="$(date +%s%N)"
tar cf "${archive}" -C "${SCCACHE_DIR}" .
pack_ns=$(( $(date +%s%N) - t0 ))

archive_bytes="$(stat -c%s "${archive}")"

# Phase 2 — network only.
#
# aws's own `--progress` stays off: it writes carriage-return updates that a
# non-TTY CI log renders as thousands of lines.
t0="$(date +%s%N)"
aws s3 cp \
  "${archive}" \
  "s3://${CACHE_S3_BUCKET}/${s3_key}" \
  --region "${CACHE_S3_REGION}" --no-progress --only-show-errors
upload_ns=$(( $(date +%s%N) - t0 ))

echo "  uploaded:    $(human "${archive_bytes}")"
awk -v a="${archive_bytes}" -v t="${tree_bytes}" \
    -v pk="${pack_ns}" -v up="${upload_ns}" 'BEGIN {
  pks = pk / 1e9; ups = up / 1e9
  printf "  pack:        %6.1fs", pks
  if (pks > 0 && t > 0) { printf "  %7.1f MiB/s  (disk -> tar)", t / 1048576 / pks }
  printf "\n"
  printf "  upload:      %6.1fs", ups
  if (ups > 0 && a > 0) { printf "  %7.1f MiB/s  (network)", a / 1048576 / ups }
  printf "\n"
  if (pks + ups > 0) {
    printf "  total:       %6.1fs  (%.0f%% pack, %.0f%% network)\n",
      pks + ups, pks / (pks + ups) * 100, ups / (pks + ups) * 100
  }
}'
