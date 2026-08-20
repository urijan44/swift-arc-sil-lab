#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="${repo_root}/Build/Binaries/strong-normal"

if [[ ! -x "${binary}" ]]; then
    "${repo_root}/Scripts/generate-artifacts.sh"
fi

# '$s...' is a literal Swift mangled symbol for LLDB.
# shellcheck disable=SC2016
lldb --batch \
    -o 'breakpoint set -n "$s6ARCLab13TrackedObjectCfd"' \
    -o run \
    -o bt \
    "${binary}"
