.DEFAULT_GOAL := flow
ROOT := $(abspath ..)
BUILD ?= $(ROOT)/artifacts/asic
TB := ../sim/unit/mul32/mul32_pattern.sv ../sim/unit/mul32/tb_mul32.sv
IMAGE := openroad/orfs@sha256:5849e1dde67ba70b36194cf90a172d6c0e4cb2cf5502d6e0dd7c1d251a6d4584
STAGE ?= finish
JOBS ?= 4

FLOW_ARGS = DESIGN_CONFIG=/work/asic/mul32/config.mk \
            WORK_HOME=/work/artifacts/asic NUM_CORES=$(JOBS)

.PHONY: flow gate-test gui

# Synthesis and physical implementation, including stage timing reports.
flow:
	mkdir -p $(BUILD)
	docker run --rm --user $$(id -u):$$(id -g) \
	    -v $(ROOT):/work:ro \
	    -v $(BUILD):/work/artifacts/asic \
	    -w /OpenROAD-flow-scripts/flow \
	    $(IMAGE) make $(FLOW_ARGS) $(STAGE)

# Zero-delay mapped-netlist simulation using the shared functional pattern.
gate-test:
	mkdir -p $(BUILD)/sim
	docker run --rm --user $$(id -u):$$(id -g) \
	    -v $(BUILD):/out $(IMAGE) bash -c ' \
	    source /OpenROAD-flow-scripts/env.sh; \
	    yosys -Q -T -p "read_liberty -ignore_miss_func /OpenROAD-flow-scripts/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib; write_verilog -noattr /out/sim/nangate45.v"'
	iverilog -g2012 -s tb_mul32 -o $(BUILD)/sim/gate \
	    $(BUILD)/results/nangate45/mul32/base/1_2_yosys.v \
	    $(BUILD)/sim/nangate45.v $(TB)
	vvp $(BUILD)/sim/gate

# SSH X11 forwarding: host networking reaches the localhost display listener.
XAUTHORITY ?= $(HOME)/.Xauthority
GUI_TARGET ?= gui_final
gui:
	@test -n "$(DISPLAY)" || { echo "Connect with ssh -Y and check DISPLAY first."; exit 1; }
	@test -r "$(XAUTHORITY)" || { echo "Set XAUTHORITY to your readable X11 cookie file."; exit 1; }
	mkdir -p $(BUILD)
	docker run --rm --network host --user $$(id -u):$$(id -g) \
	    -e DISPLAY -e XAUTHORITY=/tmp/asic.xauthority -e QT_X11_NO_MITSHM=1 \
	    -v "$(XAUTHORITY):/tmp/asic.xauthority:ro" \
	    -v $(ROOT):/work:ro \
	    -v $(BUILD):/work/artifacts/asic \
	    -w /OpenROAD-flow-scripts/flow \
	    $(IMAGE) make $(FLOW_ARGS) $(GUI_TARGET)
