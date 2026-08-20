#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sil_dir="${repo_root}/Build/SIL"
binary_dir="${repo_root}/Build/Binaries"

swiftc_cmd() {
    xcrun swiftc "$@"
}

mkdir -p "${sil_dir}" "${binary_dir}"
swiftc_cmd -version > "${repo_root}/Build/toolchain.txt" 2>&1

swiftc_cmd \
    -emit-silgen \
    -Onone \
    -module-name ARCLab \
    "${repo_root}/Examples/StrongReference.swift" \
    -o "${sil_dir}/StrongReference.raw.sil"

swiftc_cmd \
    -emit-sil \
    -Onone \
    -Xfrontend -disable-arc-opts \
    -module-name ARCLab \
    "${repo_root}/Examples/StrongReference.swift" \
    -o "${sil_dir}/StrongReference.canonical.sil"

swiftc_cmd \
    -emit-ir \
    -Onone \
    -Xfrontend -disable-arc-opts \
    -module-name ARCLab \
    "${repo_root}/Examples/StrongReference.swift" \
    -o "${sil_dir}/StrongReference.ll"

cp \
    "${sil_dir}/StrongReference.canonical.sil" \
    "${sil_dir}/StrongReference.leaky.sil"
patch \
    "${sil_dir}/StrongReference.leaky.sil" \
    "${repo_root}/SIL/remove-object-release.patch"

swiftc_cmd \
    -module-name ARCLab \
    "${sil_dir}/StrongReference.canonical.sil" \
    -o "${binary_dir}/strong-normal"

swiftc_cmd \
    -module-name ARCLab \
    "${sil_dir}/StrongReference.leaky.sil" \
    -o "${binary_dir}/strong-leaky"

swiftc_cmd \
    -emit-silgen \
    -Onone \
    -module-name WeakLab \
    "${repo_root}/Examples/WeakReference.swift" \
    -o "${sil_dir}/WeakReference.raw.sil"

swiftc_cmd \
    -emit-sil \
    -Onone \
    -Xfrontend -disable-arc-opts \
    -module-name WeakLab \
    "${repo_root}/Examples/WeakReference.swift" \
    -o "${sil_dir}/WeakReference.canonical.sil"

swiftc_cmd \
    -emit-ir \
    -Onone \
    -Xfrontend -disable-arc-opts \
    -module-name WeakLab \
    "${repo_root}/Examples/WeakReference.swift" \
    -o "${sil_dir}/WeakReference.ll"

swiftc_cmd \
    -Onone \
    -module-name WeakLab \
    "${repo_root}/Examples/WeakReference.swift" \
    -o "${binary_dir}/weak"

swiftc_cmd \
    -Onone \
    -module-name CycleLab \
    "${repo_root}/Examples/ReferenceCycle.swift" \
    -o "${binary_dir}/cycle"

swiftc_cmd \
    -emit-sil \
    -Onone \
    -Xfrontend -disable-arc-opts \
    -module-name MemoryGrowthLab \
    "${repo_root}/Examples/MemoryGrowth.swift" \
    -o "${sil_dir}/MemoryGrowth.canonical.sil"

cp \
    "${sil_dir}/MemoryGrowth.canonical.sil" \
    "${sil_dir}/MemoryGrowth.leaky.sil"
patch \
    "${sil_dir}/MemoryGrowth.leaky.sil" \
    "${repo_root}/SIL/remove-payload-release.patch"

swiftc_cmd \
    -module-name MemoryGrowthLab \
    "${sil_dir}/MemoryGrowth.canonical.sil" \
    -o "${binary_dir}/memory-normal"

swiftc_cmd \
    -module-name MemoryGrowthLab \
    "${sil_dir}/MemoryGrowth.leaky.sil" \
    -o "${binary_dir}/memory-leaky"

echo "Artifacts generated in ${repo_root}/Build"
