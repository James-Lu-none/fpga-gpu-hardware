#!/usr/bin/env bash
set -euo pipefail

# Keep command output in a log, and show it only when the command fails.
run_logged() {
    local log=$1
    shift
    "$@" >> "$log" 2>&1 || { cat "$log" >&2; exit 1; }
}


if [[ $# == 0 || $1 == --help ]]; then
    echo "Usage: $0 <test_opencl_*.c or test name> [...]"
    [[ $# != 0 ]] && exit 0 || exit 2
fi
sim_dir=$(cd "$(dirname "$0")" && pwd)
driver_dir=$(realpath "$sim_dir/../../fpga-gpu-driver")
build_dir=$(realpath -m "${BUILD:-$sim_dir/build}")
export FPGAGPU_SIM_RUNNER="$sim_dir/run_kernel.sh"
export FPGAGPU_CLANG=$(realpath -m "${FPGAGPU_CLANG:-$sim_dir/../../fpga-gpu-compiler/scripts/fpgagpu-clang}")
export FPGAGPU_RTL_SIM=$(realpath -m "${FPGAGPU_RTL_SIM:-$build_dir/gpc/Vgpc_top_tb}")
export TRACE=${TRACE:-0} OPENCL_MAX_CYCLES=${OPENCL_MAX_CYCLES:-100000}
read -r -a cc_command <<< "${CC:-cc}"
read -r -a host_flags <<< "${CFLAGS:--O2 -Wall -Wextra}"

for source in "$@"; do
    [[ -f $source ]] || source="$driver_dir/tests/${source%.c}.c"
    source=$(realpath "$source")
    name=$(basename "$source" .c)
    output="$build_dir/$name"
    rm -rf -- "$output"
    mkdir -p "$output"
    run_logged "$output/host_compile.log" "${cc_command[@]}" -std=gnu11 "${host_flags[@]}" \
        -DCL_TARGET_OPENCL_VERSION=120 -I"$driver_dir/include" -I"$driver_dir/tests" \
        "$source" "$driver_dir/tests/raw_data.c" "$sim_dir/opencl_sim.c" -o "$output/host_test"
    (cd "$output" && run_logged host.log ./host_test)
    [[ -f $output/memory.bin ]] || { echo "FAIL $name: no RTL kernel executed" >&2; exit 1; }
    if [[ $name == test_opencl_branch_divergence ]]; then
        awk '$1 == "divergence_events:" && $2 > 0 { seen=1 } END { exit !seen }' "$output/execution.txt" || {
            echo 'Expected lane divergence, but none was observed' >&2; exit 1;
        }
    fi
    echo "PASS $name ($output)"
done
