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