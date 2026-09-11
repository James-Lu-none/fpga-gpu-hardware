# FPGA-GPU: Xilinx Artix-7 (AX7A200B) PCIe Accelerator

## Tcl commands
 
dump reports:
```bash
# use pwd and cd to comfirm path before executing commands
report_utilization -hierarchical -format xml -file ./utilization.xml
report_timing -delay_type max -max_paths 50 -sort_by group -nworst 2 -file ./timing.txt

```

if using block design:

```bash
# .bd to tcl
write_bd_tcl -force build_bd.tcl
# project tcl
write_project_tcl -force recreate_project.tcl
```

## verilog attributes

```verilog
// Block RAM: use 18kb/36kb on-chip block ram without using LUT, but requires one clock cycle delay to read. cheap in logic resource.
(* ram_style = "block" *)
// Distributed RAM: use LUTs to implement RAM, but no clock cycle delay to access. expensive in logic resource.
(* ram_style = "distributed" *)

// async reg: for asynchronous clock domain crossing or manually delay signal.
(* async_reg = "true" *)
// mark debug: adding this attribute will output the signal to waveform, and vivado wont optimize it out.
(* mark_debug = "true" *)

// dont touch: preventing vivado from optimizing the signal out.
(* dont_touch = "true" *)

// max fanout: preventing vivado from driving too many logic cells with one signal.
(* max_fanout = "32" *)
```

## design decisions

### pcie ip

originally, a custom pcie ip (`axi_pcie` + custom `gpu_dma_master.v` + software page table) was used to communicate with the host. However, it was later replaced with the XDMA IP (`DMA/Bridge Subsystem for PCI Express` in AXI-Stream mode) provided by Xilinx to support Scatter-Gather (SG) DMA via Linux `dma_map_sg()`.

### riscv command processor (cp) softcore

To mirror modern GPGPU hardware architectures (e.g. NVIDIA GSP / AMD CP):
- An official **YosysHQ PicoRV32 RV32I RISC-V** core ([`rtl/picorv32.v`](file:///c:/Users/user/workspace/fpga-gpu/rtl/picorv32.v)) is integrated as an on-chip Command Processor.
- **Direct Mailbox & Hardware IRQ Architecture (0-Latency Best Practice)**:
  1. **`picorv32_axi` (CPU Softcore Top Module)**: PicoRV32 core wrapper with AXI4-Lite master interface and hardware interrupt (`irq[0]`) enabled.
  2. **`riscv_bram.v` (Dual-Port On-Chip BRAM)**:
     - **Port A**: Connected to RISC-V CPU for code and data execution.
     - **Port B**: Connected directly to PCIe XDMA BAR0 MMIO for Host PC direct Mailbox writes (`0x3F00`).
  3. **`riscv_cp_system.v` (SoC Top & Direct Mailbox Interconnect)**:
     - Detects Host writes to Mailbox address `0x3F00` and generates a 1-cycle hardware interrupt pulse (`irq[0]`).
     - Routes RISC-V AXI Master to `gpu_compute_core` (`0x4000_0000`) and HDMI SiI9134 I2C controller (`0x5000_0000`).
- **Role**:
  1. Offloads SiI9134 HDMI display controller I2C configuration.
  2. Interrupt-driven parsing of Host PCIe CUDA Task Descriptors directly from BRAM Mailbox (`0x3F00`).
  3. Dispatches parallel execution tasks to `gpu_compute_core` SIMD ALUs.
- **Resource Footprint**: Consumes ~1,200 LUTs (< 1.5% of Artix-7 XC7A200T resources) with 16KB dual-port on-chip BRAM.

### clock and reset architecture

- **PCIe Reference Clock Buffer (`IBUFDS_GTE2`)**: 
  - The PCIe 100MHz reference clock uses Bank 216 GTP dedicated reference clock pins `F10` (`sys_clk_clk_p`) and `E10` (`sys_clk_clk_n`).
  - In 7-Series FPGAs, MGTREFCLK pins cannot connect to standard single-ended `IBUF` primitives due to physical silicon routing constraints.
  - A Utility Buffer IP (`util_ds_buf`) with `C_BUF_TYPE` set to `IBUFDSGTE` (`IBUFDS_GTE2`) is instantiated in Block Design (`design_1.bd`) to convert the differential clock input into `IBUF_OUT` for `xdma_0/sys_clk`.
- **System Reset & Internal Clocking**:
  - External PCIe reset `sys_rst_n` (`T18`) feeds directly into `xdma_0/sys_rst_n`.
  - All internal user modules (`gpu_top`, `gpu_regs_slave_lite_v1_0_S00_AXI`, `gpu_compute_core`) operate on XDMA's generated clock `xdma_0/axi_aclk` (125MHz) and active-low reset `xdma_0/axi_aresetn`.

### GPU AXI4 peripheral (register space) logic modifications

The register space is built using Vivado IP Wizard generated AXI4-Lite Slave peripheral ([`rtl/gpu_regs_slave_lite_v1_0_S00_AXI.v`](file:///c:/Users/user/workspace/fpga-gpu/rtl/gpu_regs_slave_lite_v1_0_S00_AXI.v)).

1. **Pristine Register Case**:
   - The wizard-generated AXI-Lite write `case` statement remains 100% untouched for standard register write storage (`slv_reg0` .. `slv_reg15`).
   - The `assign S_AXI_RDATA` statement remains pristine Vivado template code returning `slv_reg0` .. `slv_reg15`.

2. **Encapsulated User Logic Block**:
   - All custom hardware logic is encapsulated inside the dedicated `// Add user logic here` block at the end of the module.
   - **Doorbell (`0x00`)**: Generates a 1-cycle `doorbell_pulse` start trigger when writing non-zero to `slv_reg0`.
   - **INT_STATUS (`0x04`)**: Hardware latches `slv_reg1[0] <= 1'b1` when GPU compute completes (`task_done_irq`).
   - **INT_ACK (`0x08`)**: Clears `slv_reg1[0] <= 1'b0` and generates a 1-cycle `irq_ack_pulse` when writing to `0x08` (`slv_reg2`).
   - **DMA Addresses (`0x0C`~`0x18`)**: Output continuous 64-bit bus addresses `reg_ring_dma_addr` (`{slv_reg4, slv_reg3}`) and `reg_desc_dma_addr` (`{slv_reg6, slv_reg5}`) to top-level logic.
   - **OPCODE (`0x1C`)**: Outputs 32-bit SIMD vector opcode `reg_opcode` (`slv_reg7`).

### cuda kernel submission & host pipeline

- **Host Task Descriptor Application ([`host/cuda_kernel_submit.cpp`](file:///c:/Users/user/workspace/fpga-gpu/host/cuda_kernel_submit.cpp))**:
  - Provides a CUDA-like kernel submission C++ runtime application.
  - Constructs 64-byte aligned `cuda_task_descriptor` (Magic `0x43554441`, Opcode, Grid/Block dimensions, DMA pointers).
  - Streams vector payload data to FPGA over XDMA H2C device (`/dev/xdma0_h2c_0`).
  - Triggers GPU doorbell register (`0x00`) via XDMA User BAR MMIO (`/dev/xdma0_user`).
  - Reads back parallel GPU compute results from C2H device (`/dev/xdma0_c2h_0`) and verifies 100% numerical correctness.

### cuda compute core & shared memory (smem) hierarchy

- **SIMD Vector Compute Core ([`rtl/gpu_compute_core.v`](file:///c:/Users/user/workspace/fpga-gpu/rtl/gpu_compute_core.v))**:
  - Implements an AXI4-Stream 64-bit SIMD vector compute pipeline.
  - **CUDA Shared Memory (SMEM / Scratchpad SRAM)**: Integrates an ultra-fast 256-word x 64-bit On-Chip SRAM inside the core, mirroring modern NVIDIA GPU Memory Hierarchies (RMEM/SMEM tier).
  - **Supported Opcodes**:
    - **`Opcode 1` (Vector Add)**: $Output = Input + 1$ (Streams to C2H).
    - **`Opcode 2` (Vector Multiply)**: $Output = Input \times 2$ (Streams to C2H).
    - **`Opcode 3` (CUDA Parallel Render)**: Computes 24-bit RGB pixel data and writes directly to Framebuffer VRAM (`framebuffer_ram.v`) for HDMI 1080P output.
    - **`Opcode 4` (SMEM Write)**: Stores incoming stream payload into SMEM Scratchpad SRAM.
    - **`Opcode 5` (SMEM Multi-Pass Accumulate)**: Multi-pass execution ($Output[i] = Input[i] + \text{SMEM}[i]$).

### GPC to framebuffer

lsu module in sm_processing_block will only write to L2 cache instead of writing directly to Framebuffer bram to simplify implementation.

### Memory Hierarchy

- Vector Register File (VRF): instantiat at processing_block level, serve for all threads (alus) in a processing_block
- L1 cache: instatiat at SM level, serve for all processing_block in a SM
- L2 cache: instatiat at GPC level, serve for all SMs in a GPC


### cache design

full address (ex: 32 bits)
cache line size: 256 bits = 32 bytes -> 5 bits offset (addr[4:0])
-> block ID: 32 - 5 = 27 bits (addr[31:5])
associative addressing: three ways of mapping memory blocks into cache lines:
1. Fully associative: 
   - Every memory block can be cached in ANY available cache line.
   - Tag: 27 bits (addr[31:5], directly equals Block ID)
   - Block Offset: 5 bits (addr[4:0])
   - Pros/Cons: No conflict misses (no thrashing), but requires comparing tags across ALL cache lines simultaneously (expensive CAM / parallel comparators) and needs a replacement policy when full.
2. Direct mapped (currently used in L1 & L2): 
   - Every block maps to exactly ONE fixed cache line determined by its index.
   - Tag: 21 bits (addr[31:11] for L1)
   - Index: 6 bits = 64 entries (addr[10:5] for L1)
   - Block Offset: 5 bits (addr[4:0])
   - Pros/Cons: Very cheap in hardware (only 1 tag comparison per access, no replacement policy needed). But susceptible to thrashing if multiple accessed addresses share the same index but have different tags.
3. Set associative (N-way): 
   - Balanced between 1 and 2. The cache is divided into S sets, where each set contains N cache lines (N-way).
   - A block maps to a fixed Set (via Set Index), but can occupy ANY of the N lines within that Set.
   - Set count S = (Total Lines) / N. Set Index bits = log2(S).
   - Needs N tag comparators and a replacement policy (LRU/FIFO/Random) per set.
* Replacement algorithms (used in Fully Associative & Set Associative when a set/cache is full):
1. FIFO (First In First Out)
2. LRU (Least Recently Used)
3. LFU (Least Frequently Used)
4. Random

* since we have limited resource on FPGA, so we choose to implement l1 and l2 cache to both use direct-mapped cache 

And for write policies we have:
1. Write Through: every write to the cache also write to memory
2. Write back: update memory only when a dirty line is replaced

* we do write through and no-write-allocate (don't grab from memory is write miss) also for simplicity

And for Flags we have:
1. Type: idicates whethere its data for instuction
2. Valid: Indicates if the line contains valid cached data. Required for Tag Hit evaluation.
3. Lock: lock a line to prevent replacement
4. dirty: Identify a line that has been written but not updated in mem

Because both our L1 and L2 caches implement a Write-Through policy, the cache content is never out of sync. Therefore, no dirty tracking is required. And since we use a seperate cache (I-RAM) for instruction so type is not required too. Also Lock is not required too.

### solving cache incoherence

Since DRAM allows read/write from both Host PCIe XDMA and L2 Cache through axi_crossbar_0, if the Host updates memory via XDMA, the L2/L1 cache is unaware of this update (no hardware bus snooping in the crossbar). If the GPU reads that address, it would hit stale cached data.

so we implement Software / Hardware-Triggered Cache Invalidation (Flush):
- GPC Control Register provides a `cache_flush` pulse:
  1. Automatic Invalidation: Every time a Kernel is launched (`hw_trigger` written via offset `0x00`), `cache_flush` automatically pulses for 1 cycle.
  2. Explicit Invalidation: Host / RISC-V can write to offset `0x28` (or `0x00` bit 1) to explicitly invalidate caches on demand.
- Both L1 Cache (64 lines) and L2 Cache (512 lines) implement `valid_ram` using distributed registers (flip-flops), clearing all valid bits to `0` in a single clock cycle without latency penalty. This forces subsequent GPU memory accesses to miss and fetch the latest data updated by XDMA from DRAM.

### issues during implementation

The entire system uses XDMA's generated clock (axi_aclk: 125MHz) and asynchronous reset (axi_aresetn)

1. Reset across clock domains: reset from XDMA to HDMI IP
  In HDMI top module, a MMCME2_BASE ip is used to generate pixel clock (clk_pix), which is desynchronized with XDMA's clock domain. So when we try to reset HDMI module with axi_aresetn, it will not be reset properly. To fix this issue, we use a two-flop synchronizer to convert the asynchronous reset to a synchronous reset for the HDMI IP. (see rtl/hdmi/hdmi_top.sv:66 in detail)

2. Setup/Hold time violations from XDMA to GPU submodules
  Since in GPU modules, there are thousands of registers connected to the global reset signal (`axi_aresetn`), the massive fanout and long routing distances across the FPGA fabric cause severe recovery/removal time violations. Thus, a Reset Tree (Reset Pipeline) is implemented, so that each reset net is locally bounded, ensuring perfect timing closure regardless of chip size. In this project, the reset signal from XDMA is only distributed to the top-level GPU module. Then, the reset signal is registered at each hierarchical boundary (e.g., Top -> GPC -> SM -> Submodules).

3. reduce fanout for reset signal
  By removing reset logic from all "Datapath" registers (e.g., 256-bit buses, operands) and only resetting "Control" registers (e.g., FSM states, valid signals).

4. time violation from opcode to warp_nzp (long path in ALU)
  original combinational route/pipeline: opcode -> ALU (including 32x32 DSP multiplier) -> zero comparator -> warp_nzp_reg.
  This route takes >10ns because 32x32 multiplication on Artix-7 requires cascading multiple DSP slices, causing massive internal propagation delay.
  **Fix**: We implemented a 2-cycle execution pipeline in `alu.sv` and `pc.sv`. We added an `EX1` stage to explicitly register the outputs of the add/sub/mul operators. This forces Vivado to use the internal pipeline registers of the DSP (`MREG`) and CARRY4 blocks, cutting the combinational logic path in half. The condition code evaluations (NZP) and write-backs are performed in the `EX2` and `EX3` stages. Because the `warp_context` scheduler uses a decoupled handshake (`ctx_wb.valid`), adding latency to the ALU does not cause data hazards.

5. time violation from current_sm to valid_ram and m_axi_araddr in l2_cache
  original combinational route/pipline: current_sm (Arbiter MUX) -> req_addr (sliced into req_index) -> valid_ram / tag_ram (LUTRAM Asynchronous Read) -> 18-bit Tag Comparator -> FSM Logic -> valid_ram WE / m_axi_awaddr.
  This 1-cycle cache architecture puts the arbitration MUX, RAM read, Tag compare, and AXI state transition all in a single cycle (`STATE_IDLE`), causing a massive combinational path.
  **Fix**: We pipelined the L2 cache arbitration by introducing a new FSM state `STATE_COMPARE`. In `STATE_IDLE`, the arbiter only determines the winning SM and latches the request into pipeline registers (`latched_req_*`). In `STATE_COMPARE`, the FSM uses the latched request to index the RAMs, execute the hit/miss logic, and determine the next AXI state. This isolates the arbitration MUX into its own cycle and completely breaks the critical path into the Cache RAM address decoders.