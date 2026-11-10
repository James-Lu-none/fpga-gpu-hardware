# Simulation

Run from the hardware repository root:

```sh
make -C sim check
make -C sim check TESTS=test_opencl_vector_add.c
make -C sim mul32-check
```

- `unit/`: multiplier, vector register file, cache store and LSU reset tests.
- `system/`: GPC integration testbench.
- `models/`: behavioral AXI VRAM model.
- `build/`: generated simulators, logs and workload results.
- `../tests/`: assembly test programs and data.

`check` runs the unit regressions and OpenCL workloads. Existing individual
`vrf-check`, `cache-store-check`, `lsu-reset-check` and `gpc-sim` targets remain.
The VRF scoreboard accepts requests on `decode.valid && decode.ready` and
checks two-cycle latency from acceptance, including overlap with write-back.
Issue performance counters likewise count `valid && ready`, not held requests.
The multiplier harness and pattern are also used by `../asic/Makefile` for
RTL and mapped-netlist simulation; ASIC flow configuration stays in `asic/`.

## OpenCL simulation flow

1. Makefile builds `build/gpc/Vgpc_top_tb`.
2. `run_sim.sh` builds and runs the selected host test.
3. `opencl_sim.c` invokes `run_kernel.sh` when a kernel is dispatched.
4. `run_kernel.sh` compiles the kernel and runs the RTL simulator.
5. The host test compares returned results with its CPU reference.
