#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary_dir="${repo_root}/Build/Binaries"

"${repo_root}/Scripts/generate-artifacts.sh"

echo
echo "[1] Original SIL"
"${binary_dir}/strong-normal"

echo
echo "[2] strong_release removed"
"${binary_dir}/strong-leaky"

echo
echo "[3] Weak reference"
"${binary_dir}/weak"

echo
echo "[4] Strong reference cycle"
"${binary_dir}/cycle"

echo
echo "[5] Maximum RSS: original SIL"
/usr/bin/time -l "${binary_dir}/memory-normal" 2>&1 \
    | awk '/checksum|maximum resident set size/'

echo
echo "[6] Maximum RSS: strong_release removed"
/usr/bin/time -l "${binary_dir}/memory-leaky" 2>&1 \
    | awk '/checksum|maximum resident set size/'
