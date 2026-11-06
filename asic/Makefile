.DEFAULT_GOAL := flow
ROOT := $(abspath ..)
BUILD ?= $(ROOT)/artifacts/asic
TB := ../sim/unit/mul32/mul32_pattern.sv ../sim/unit/mul32/tb_mul32.sv
IMAGE := openroad/orfs@sha256:5849e1dde67ba70b36194cf90a172d6c0e4cb2cf5502d6e0dd7c1d251a6d4584
JOBS ?= 4

FLOW_ARGS = DESIGN_CONFIG=/work/asic/mul32/config.mk \
            WORK_HOME=/work/artifacts/asic NUM_CORES=$(JOBS) \
            KLAYOUT_LVS_FILE=/work/asic/lvs/lvs_freepdk45.lylvs
DOCKER = docker run --rm --user $$(id -u):$$(id -g) \
         -v $(ROOT):/work:ro -v $(BUILD):/work/artifacts/asic \
         -w /OpenROAD-flow-scripts/flow
RESULTS := $(BUILD)/results/nangate45/mul32/base
REPORTS := $(BUILD)/reports/nangate45/mul32/base

.PHONY: flow signoff sta drc lvs ir gate-test gui

# Require an explicit ORFS stage; no tool runs when STAGE is empty.
flow:
	@test -n "$(strip $(STAGE))" || { echo "Specify STAGE=synth|floorplan|place|cts|route|finish; use signoff for checks."; exit 1; }
	mkdir -p $(BUILD)
	$(DOCKER) $(IMAGE) make $(FLOW_ARGS) $(STAGE)

# Require an existing final design instead of silently implementing it here.
signoff:
	@for ext in odb sdc spef gds v; do \
	    test -s $(RESULTS)/6_final.$$ext || { echo "Missing final $$ext; run make -C asic flow STAGE=finish first."; exit 1; }; \
	done
	$(MAKE) sta
	$(MAKE) drc
	$(MAKE) lvs
	$(MAKE) ir

# Reload final artifacts for standalone timing and static IR reports.
sta ir:
	mkdir -p $(BUILD)
	$(DOCKER) -e CHECK=$@ $(IMAGE) \
	    bash -c 'source /OpenROAD-flow-scripts/env.sh; openroad -exit /work/asic/mul32/verify.tcl' \
	    > $(BUILD)/$@.log 2>&1 || { cat $(BUILD)/$@.log; exit 1; }
	cat $(BUILD)/$@.log

# Remove cached comparison reports so each signoff request reruns the checks.
drc:
	rm -f $(REPORTS)/6_drc.lyrdb $(REPORTS)/6_drc_count.rpt
	$(DOCKER) $(IMAGE) make $(FLOW_ARGS) drc
	@test "$$(cat $(REPORTS)/6_drc_count.rpt)" -eq 0 || { echo "DRC violations found; inspect $(REPORTS)/6_drc.lyrdb"; exit 1; }

lvs:
	rm -f $(RESULTS)/6_lvs.lvsdb
	$(DOCKER) $(IMAGE) make $(FLOW_ARGS) lvs

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
