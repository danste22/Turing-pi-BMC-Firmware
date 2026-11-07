#!/usr/bin/env bash
# List Buildroot per-package output directories (name-version) from a finished build.
# Usage: ./scripts/list-bmc-buildroot-package-dirs.sh [buildroot-output-dir]
# Default output dir: <repo>/buildroot/output (same as ./scripts/configure.sh default).

set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:-"${root}/buildroot/output"}
if [[ ! -d "${out}/build" ]]; then
	echo "Expected ${out}/build (run a full image build first)." >&2
	exit 1
fi
ls -1 "${out}/build" | LC_ALL=C sort -f
