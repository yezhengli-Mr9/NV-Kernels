#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
work=/home/kerneltester/nv725-experiment
mkdir -p "$work"
exec > >(tee "$work/experiment.log") 2>&1
trap 'status=$?; printf "EXPERIMENT_EXIT=%s\n" "$status"; if [ "$status" != 0 ]; then for log in "$work"/*-config.log "$work"/*-boot.log "$work"/*-negative.log; do if [ -f "$log" ]; then printf "\nFAILURE_LOG=%s\n" "$log"; tail -n 20 "$log"; fi; done; fi; if [ -f "$work/summary.txt" ]; then cat "$work/summary.txt"; fi' EXIT

date -u
uname -a
cat /etc/os-release
printf 'CPUS=%s\n' "$(nproc)"
if ! command -v vng || ! command -v flex || ! command -v bison; then
    apt-get update
    apt-get install -y build-essential flex bison libssl-dev bc \
        libelf-dev libncurses-dev python3-yaml virtme-ng qemu-system-x86 \
        git curl rsync cpio kmod
fi
vng --version
gcc --version | head -n 1
qemu-system-x86_64 --version | head -n 1
python3 - <<'PY'
from pathlib import Path
import yaml

workflow = yaml.load(
    Path("/var/tmp/nv725-experiment/candidate-kernel-build.yml").read_text(),
    Loader=yaml.BaseLoader,
)
for event in ("workflow_dispatch", "workflow_call"):
    build_ref = workflow["on"][event]["inputs"]["build_ref"]
    assert build_ref["type"] == "string", (event, build_ref)
    assert build_ref["required"] == "true", (event, build_ref)
    assert "options" not in build_ref, (event, build_ref)
assert workflow["jobs"]["build"]["strategy"]["matrix"]["include"] == [
    {"runs-on": "ubuntu-latest", "config": "defconfig",
     "arch": "x86_64", "page_size": "4096"},
    {"runs-on": "ubuntu-24.04-arm", "config": "config_4k",
     "arch": "aarch64", "page_size": "4096"},
    {"runs-on": "ubuntu-24.04-arm", "config": "config_64k",
     "arch": "aarch64", "page_size": "65536"},
]
print("CANDIDATE_REF_SCHEMA_AND_EXISTING_MATRIX_PASS")
PY
echo 'CANDIDATE_REF_SCHEMA_AND_EXISTING_MATRIX_PASS' >> "$work/summary.txt"

git clone --quiet --depth 1 --single-branch --branch ci/ubuntu24-nvidia-arm64-boot-checks \
    https://github.com/yezhengli-Mr9/NV-Kernels.git "$work/workflow"
test "$(git -C "$work/workflow" rev-parse HEAD)" = 95f9613faa7874a065955664880433031ac93524
verifier="$work/workflow/.github/scripts/verify-kernel-boot.sh"
bash -n "$verifier"
python3 "$work/workflow/.github/scripts/test_verify_kernel_boot.py" -v
echo 'VERIFIER_TESTS_PASS=7' >> "$work/summary.txt"

for entry in \
    '24.04_linux-nvidia-7.0-next:18f0eb33acddde0398e7b76354ad9840e3192174' \
    '26.04_linux-nvidia-7.3-next:4bad1c1252a59874186ac06365ca9d3f8cabc709'
do
    branch=${entry%%:*}
    expected_sha=${entry#*:}
    source="$work/$branch"
    printf '\nSOURCE_BRANCH=%s SOURCE_SHA=%s\n' "$branch" "$expected_sha"
    git clone --quiet --depth 1 --single-branch --branch "$branch" \
        https://github.com/NVIDIA/NV-Kernels.git "$source"
    test "$(git -C "$source" rev-parse HEAD)" = "$expected_sha"
    cd "$source"
    vng -vb --kconfig > "$work/$branch-config.log" 2>&1
    ./scripts/config --disable CONFIG_WERROR
    ./scripts/config --disable SYSTEM_TRUSTED_KEYS
    ./scripts/config --disable SYSTEM_REVOCATION_KEYS
    start=$(date +%s)
    if ! vng -vb > "$work/$branch-build.log" 2>&1; then
        tail -n 60 "$work/$branch-build.log"
        exit 1
    fi
    expected_release=$(cat include/config/kernel.release)
    : "${expected_release:?Missing build-generated kernel release}"
    printf 'BUILD_PASS branch=%s release=%s seconds=%s\n' \
        "$branch" "$expected_release" "$(( $(date +%s) - start ))" | tee -a "$work/summary.txt"
    cp "$verifier" ./verify-kernel-boot.sh
    vng -v -m 4G -- bash ./verify-kernel-boot.sh \
        x86_64 4096 "$expected_release" > "$work/$branch-boot.log" 2>&1
    grep -F "Kernel release: expected=$expected_release actual=$expected_release" \
        "$work/$branch-boot.log"
    grep -F 'Architecture: expected=x86_64 actual=x86_64' "$work/$branch-boot.log"
    grep -F 'Page size: expected=4096 actual=4096' "$work/$branch-boot.log"
    printf 'QEMU_BOOT_PASS branch=%s\n' "$branch" | tee -a "$work/summary.txt"
    if vng -v -m 4G -- bash ./verify-kernel-boot.sh \
        x86_64 4096 "$expected_release-stale" > "$work/$branch-negative.log" 2>&1; then
        echo 'ERROR: stale guest kernel was accepted'
        exit 1
    fi
    grep -F "Kernel release: expected=$expected_release-stale actual=$expected_release" \
        "$work/$branch-negative.log"
    printf 'QEMU_STALE_RELEASE_REJECTED branch=%s\n' "$branch" | tee -a "$work/summary.txt"
done
echo 'BOTH_NVIDIA_BRANCH_BUILDS_AND_QEMU_BOOTS_PASS'
