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

shared_key="sccache-cache/${cache_name}-${RUNNER_OS}-${RUNNER_ARCH}.tar"

human() { numfmt --to=iec --suffix=B -- "$1" 2>/dev/null || printf '%s bytes' "$1"; }

mkdir -p "$SCCACHE_DIR"

if [ -z "${CACHE_S3_BUCKET:-}" ]; then
  echo "::warning::S3 cache bucket not configured on this runner; sccache starts cold"
  exit 0
fi

# The archive is downloaded in full before it is unpacked, rather than piped
# straight into `tar`. Two reasons:
#
#   - A download that dies partway never touches SCCACHE_DIR. Piping extracts as
#     bytes arrive, so a failure mid-stream leaves a half-populated cache that
#     the fallback below would then unpack on top of.
#   - The transfer and the unpack stay separately measurable. In a pipe the
#     faster stage just blocks on the slower one, so neither can be attributed
#     any time of its own.
#
# The cost is peak disk (archive alongside the tree it expands into) and the
# lost overlap between the two phases.
stage_dir="$(dirname "${SCCACHE_DIR}")"
archive="${stage_dir}/.sccache-restore-$$.tar"
trap 'rm -f "${archive}"' EXIT

# Informational, not a gate: the workflow step is `continue-on-error`, so
# running out of room here costs a cold cache rather than a red build.
avail_bytes="$(df -PB1 "${stage_dir}" | awk 'NR == 2 { print $4 }')"
cap_bytes="$(numfmt --from=iec "${SCCACHE_CACHE_SIZE:-0}" 2>/dev/null || echo 0)"
echo "Staging area ${stage_dir}: $(human "${avail_bytes}") free"
if [ "${cap_bytes}" -gt 0 ] && [ "${avail_bytes}" -lt $(( cap_bytes * 2 )) ]; then
  echo "::warning::Less than 2x SCCACHE_CACHE_SIZE free; the restore may run out of space"
fi

# NOTE: this runs from `if` and `||` contexts below, which suspend `set -e` for
# the whole function body — so every failure has to `return` explicitly rather
# than relying on the shell to abort.
restore() {
  local key="$1"
  local s3_key="${CACHE_S3_KEY_PREFIX}${key}"
  local t0 download_ns extract_ns archive_bytes tree_bytes

  echo "Restoring sccache cache, key: ${key}"

  # Phase 1 — network only. `aws s3 cp` remains the sole arbiter of hit-vs-miss.
  #
  # aws's own `--progress` stays off: it writes carriage-return updates that a
  # non-TTY CI log renders as thousands of lines.
  t0="$(date +%s%N)"
  aws s3 cp \
    "s3://${CACHE_S3_BUCKET}/${s3_key}" \
    "${archive}" \
    --region "${CACHE_S3_REGION}" --no-progress --only-show-errors || return 1
  download_ns=$(( $(date +%s%N) - t0 ))

  archive_bytes="$(stat -c%s "${archive}")"

  # Phase 2 — unpack only. The archive is uncompressed: sccache already
  # zstd-compresses its cache entries, so gzip measured 1.02x here while costing
  # more wall time than the download it was shrinking.
  t0="$(date +%s%N)"
  tar xf "${archive}" -C "${SCCACHE_DIR}" || return 1
  extract_ns=$(( $(date +%s%N) - t0 ))

  rm -f "${archive}"
  tree_bytes="$(du -sb "${SCCACHE_DIR}" | cut -f1)"

  echo "  downloaded:  $(human "${archive_bytes}")"
  echo "  on disk:     $(human "${tree_bytes}")"
  awk -v a="${archive_bytes}" -v t="${tree_bytes}" \
      -v dl="${download_ns}" -v ex="${extract_ns}" 'BEGIN {
    dls = dl / 1e9; exs = ex / 1e9
    printf "  download:    %6.1fs", dls
    if (dls > 0 && a > 0) { printf "  %7.1f MiB/s  (network)", a / 1048576 / dls }
    printf "\n"
    printf "  unpack:      %6.1fs", exs
    if (exs > 0 && t > 0) { printf "  %7.1f MiB/s  (tar -> disk)", t / 1048576 / exs }
    printf "\n"
    if (dls + exs > 0) {
      printf "  total:       %6.1fs  (%.0f%% network, %.0f%% unpack)\n",
        dls + exs, dls / (dls + exs) * 100, exs / (dls + exs) * 100
    }
  }'

  # Explicit: the caller reads a non-zero return as a cache miss, so the
  # function must not leak the status of whatever reporting ran last.
  return 0
}

# PR-scoped first (isolates concurrent PRs from each other), falling back to
# the shared merge_group/main cache — mainly so a PR's first push isn't cold.
if [ -n "$pr_number" ]; then
  pr_key="sccache-cache/${cache_name}-${RUNNER_OS}-${RUNNER_ARCH}-pr${pr_number}.tar"
  if restore "$pr_key"; then
    exit 0
  fi
  echo "No PR-scoped cache found, falling back to shared cache"
fi

restore "$shared_key" || echo "::warning::No sccache cache found; starting cold"
