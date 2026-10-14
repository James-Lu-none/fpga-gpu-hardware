.DEFAULT_GOAL := check
CC ?= cc
VERILATOR ?= verilator
JOBS ?= 2
OPENCL_MAX_CYCLES ?= 100000
TRACE ?= 1
FPGAGPU_CLANG ?= ../../fpga-gpu-compiler/scripts/fpgagpu-clang
BUILD := build
RTL := ../rtl
DRIVER := ../../fpga-gpu-driver

TESTS ?= test_opencl_matmul.c test_opencl_vector_add.c test_opencl_matmul_occupancy.c test_opencl_branch_divergence.c

GPC_SOURCES := \
	$(RTL)/gpu_pkg.sv \
	$(wildcard $(RTL)/common/*.sv) \
	$(wildcard $(RTL)/sm/*.sv) \
	$(wildcard $(RTL)/sm/sp/*.sv) \
	$(wildcard $(RTL)/sm/sp/unit/*.sv) \
	$(wildcard $(RTL)/gpc/*.sv)

FLAGS := --binary --timing --trace --assert -j $(JOBS) -Wno-fatal -I$(RTL)/common
.PHONY: check gpc-sim lint clean
.DELETE_ON_ERROR:

export CC CFLAGS VERILATOR JOBS OPENCL_MAX_CYCLES TRACE BUILD FPGAGPU_CLANG

check: gpc-sim
	./run_sim.sh $(TESTS)

gpc-sim: $(BUILD)/gpc/Vgpc_top_tb

lint:
	$(VERILATOR) --lint-only --timing -Wno-fatal -I$(RTL)/common --top-module gpc_top_tb $(GPC_SOURCES) axi_vram_model.sv gpc_top_tb.sv

clean:
	$(RM) -r -- "$(BUILD)"

$(BUILD)/gpc/Vgpc_top_tb: gpc_top_tb.sv axi_vram_model.sv $(GPC_SOURCES)
	mkdir -p $(BUILD)
	$(VERILATOR) $(FLAGS) --top-module gpc_top_tb --Mdir $(BUILD)/gpc $(GPC_SOURCES) axi_vram_model.sv gpc_top_tb.sv > $(BUILD)/gpc_compile.log 2>&1 || { cat $(BUILD)/gpc_compile.log; exit 1; }

