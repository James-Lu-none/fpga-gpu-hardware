.DEFAULT_GOAL := check
CC ?= cc
VERILATOR ?= verilator
JOBS ?= 2
OPENCL_MAX_CYCLES ?= 100000
# rtl/top.sv clocks GPC from XDMA axi_aclk (125 MHz in xdma_0.xci).
GPC_CLOCK_HZ ?= 125000000
TRACE ?= 1
FPGAGPU_CLANG ?= ../../fpga-gpu-compiler/scripts/fpgagpu-clang
BUILD := build
RTL := ../rtl
DRIVER := ../../fpga-gpu-driver

TESTS ?= \
	test_opencl_minimal.c \
	test_opencl_minimal_branch.c \
	test_opencl_matmul.c \
	test_opencl_vector_add.c \
	test_opencl_matmul_occupancy.c \
	test_opencl_branch_divergence.c

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

export CC CFLAGS VERILATOR JOBS OPENCL_MAX_CYCLES GPC_CLOCK_HZ TRACE BUILD FPGAGPU_CLANG

check: lsu-reset-check cache-store-check gpc-sim
	./run_sim.sh $(TESTS)

gpc-sim: $(BUILD)/gpc/Vgpc_top_tb

lint:
	$(VERILATOR) --lint-only --timing -Wno-fatal -I$(RTL)/common --top-module gpc_top_tb $(GPC_SOURCES) axi_vram_model.sv gpc_top_tb.sv

clean:
	$(RM) -r -- "$(BUILD)"

$(BUILD)/gpc/Vgpc_top_tb: gpc_top_tb.sv axi_vram_model.sv $(GPC_SOURCES)
	mkdir -p $(BUILD)
	$(VERILATOR) $(FLAGS) --top-module gpc_top_tb --Mdir $(BUILD)/gpc $(GPC_SOURCES) axi_vram_model.sv gpc_top_tb.sv > $(BUILD)/gpc_compile.log 2>&1 || { cat $(BUILD)/gpc_compile.log; exit 1; }


.PHONY: lsu-reset-check
lsu-reset-check: $(BUILD)/lsu-reset/Vlsu_reset_tb
	./$(BUILD)/lsu-reset/Vlsu_reset_tb

$(BUILD)/lsu-reset/Vlsu_reset_tb: lsu_reset_tb.sv $(GPC_SOURCES)
	mkdir -p $(BUILD)/lsu-reset
	$(VERILATOR) --binary --timing --assert -j $(JOBS) -Wno-fatal -I$(RTL)/common --top-module lsu_reset_tb --Mdir $(BUILD)/lsu-reset $(RTL)/gpu_pkg.sv $(RTL)/common/gpu_interfaces.sv $(RTL)/sm/sp/lsu.sv lsu_reset_tb.sv > $(BUILD)/lsu-reset/compile.log 2>&1 || { cat $(BUILD)/lsu-reset/compile.log; exit 1; }

.PHONY: cache-store-check
cache-store-check: $(BUILD)/cache-store/Vcache_store_tb
	./$(BUILD)/cache-store/Vcache_store_tb

$(BUILD)/cache-store/Vcache_store_tb: cache_store_tb.sv $(RTL)/common/unified_cache.sv $(RTL)/common/cache_if.sv $(RTL)/gpu_pkg.sv
	mkdir -p $(BUILD)/cache-store
	$(VERILATOR) --binary --timing --assert -j $(JOBS) -Wno-fatal -I$(RTL)/common --top-module cache_store_tb --Mdir $(BUILD)/cache-store $(RTL)/gpu_pkg.sv $(RTL)/common/cache_if.sv $(RTL)/common/unified_cache.sv cache_store_tb.sv > $(BUILD)/cache-store/compile.log 2>&1 || { cat $(BUILD)/cache-store/compile.log; exit 1; }
