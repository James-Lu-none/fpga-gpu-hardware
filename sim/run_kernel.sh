#!/usr/bin/env bash
# Called by opencl_sim.c from the host test's output directory.
set -euo pipefail
rm -f compiler.log rtl.log memory.bin counters.txt execution.txt gpc.vcd
if ! {
    "$FPGAGPU_CLANG" --save-temps -x kernel.c -o kernel.hex &&
    "$FPGAGPU_CLANG" -S kernel.c -o kernel.s
} > compiler.log 2>&1; then
    cat compiler.log >&2
    exit 1
fi
args=(+program=kernel.hex +memory=memory.hex +config=gpc_config.txt
      +dump=memory.bin "+max_cycles=${OPENCL_MAX_CYCLES:-100000}")
[[ ${TRACE:-0} != 1 ]] || args+=(+trace=gpc.vcd)
if ! "$FPGAGPU_RTL_SIM" "${args[@]}" > rtl.log 2>&1; then
    cat rtl.log >&2
    exit 1
fi
