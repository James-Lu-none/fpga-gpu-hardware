# simulation flow

running following command:

```bash
make -C sim check TESTS=test_opencl_vector_add.c
```

will generate following simulation flow

1. Makefile: build Vgpc_top_tb
2. run_sim.sh: build test_opencl_vector_add.c to generate host_test, run host_test
3. host_test calls clEnqueueNDRangeKernel() in opencl_sim.c
4. clEnqueueNDRangeKernel() calls execute_simulator (run_kernel.sh)
5. run_kernel.sh: build kernel.c to generate kernel.hex／kernel.s, run RTL
6. host_test: read result back and compare with CPU result

With GPU debug enabled, AXI-Lite exposes the first accepted DDR transactions of
each launch:

- `0x80`: Seen flags: bit 0 AR, bit 1 R, bit 2 AW, bit 3 W
- `0x84`: First read address
- `0x88–0xA4`: First read line, eight 32-bit words, low word first
- `0xA8`: First write address
- `0xAC`: First write byte strobe
- `0xB0–0xB4`: Low 64 bits of first write data
