# FPGA-GPU End-to-End Pipeline Specification

## Architecture Overview

```text
Host (x86_64 Linux) -> PCIe XDMA -> Mailbox BRAM (0x3F00)
                    -> PicoRV32 Command Processor
                    -> GPC Control Registers (0x1000_0000)
                    -> Thread Block Scheduler (TBS)
                    -> SMs (SM Controller / CTA Dispatcher)
                    -> Sub-Partitions (Warp Context, Fetch/Decode, VRF, ALU/LSU)
                    -> L1 Cache -> L2 Cache -> DDR3
```

## Execution Flow

### 1. Host to RISC-V Command Processor (PCIe XDMA -> Mailbox -> IRQ)

- Host driver (vgpu_core.ko) writes a 64-byte aligned task descriptor to Mailbox BRAM at address 0x3F00 via PCIe XDMA BAR0 MMIO.
- Hardware in gpu_top.sv sniffs AXI-Lite writes to the mailbox range:
  When s_axi_lite.awaddr[15:0] == 16'h3F00, it pulses doorbell_irq_reg <= 1'b1 for 1 cycle.
  This signal is hardwired directly to picorv32_axi.irq[0].
- PicoRV32 firmware (main.c) wakes up from wfi (Wait For Interrupt), enters irq_handler(), and reads the task descriptor:
  grid_dim_x, grid_dim_y, block_dim_x, block_dim_y, src_addr, dst_addr, and instruction binary.

### 2. RISC-V CP to GPC Control Registers

- PicoRV32 uses AXI-Lite bus rv_gpu_axil to write to gpc_control_register.sv (base 0x1000_0000):
  - 0x0C: grid_dim_x (16-bit)
  - 0x10: grid_dim_y (16-bit)
  - 0x14: block_dim_x (16-bit)
  - 0x18: block_dim_y (16-bit)
  - 0x20: src_addr (32-bit)
  - 0x24: dst_addr (32-bit)

- Instruction RAM loading:
  For each instruction i, firmware writes:
  - 0x30: iram_waddr_reg <= i (12-bit)
  - 0x34: iram_wdata_reg <= instruction (32-bit)
  Writing to 0x34 automatically asserts iram_we_reg for 1 cycle, broadcasting the instruction to all SMs and Sub-Partitions.

- Launch trigger:
  Firmware writes 0x01 to 0x00, which pulses hw_trigger for 1 cycle to start the hardware scheduler.

### 3. Thread Block Scheduler (TBS) & Block Formation

Module: thread_block_scheduler.sv (instantiated in gpc_top.sv)

State machine:
- STATE_IDLE (0): waits for hw_trigger.
- STATE_ISSUE (1): calculates thread blocks and schedules them.
- STATE_WAIT_ACK (2): waits for the selected SM to accept the block.
- STATE_WAIT_DONE (3): waits for all blocks and SMs to finish.

Logic:
- Total threads per block: threads_per_block = block_dim_x * block_dim_y
- Warps per block: warps_per_block = (threads_per_block + WARP_SIZE - 1) / WARP_SIZE
- Current block coordinates: current_block_x, current_block_y

Resource sampling & arbitration:
- Each SM outputs its free warp capacity via available_warp_slots (5-bit).
- In gpc_top.sv, these are packed into sm_available_warp_slots[(n*5) +: 5].
- TBS scans all SMs to find the one with the most free slots:
  sm_slots[j] >= warps_per_block and sm_slots[j] > max_slots
- When best_sm is chosen, TBS drives:
  ```systemverilog
  sm_block_issue_valid[best_sm] <= 1'b1;
  sm_block_idx_x                <= current_block_x;
  sm_block_idx_y                <= current_block_y;
  sm_warps_per_block            <= warps_per_block;
  state                         <= STATE_WAIT_ACK;
  ```
- Handshake: TBS waits for sm_block_accepted[best_sm] == 1'b1, then advances current_block_x/y. When all blocks in the grid are dispatched, TBS enters STATE_WAIT_DONE.

### 4. SM Controller & Warp Formation

Module: sm_top.sv (inlined CTA dispatcher)

State machine:
- ST_IDLE (0): waits for block_issue_valid == 1'b1 from TBS.
- ST_ISSUE_WARP (1): asserts allocation request to Sub-Partition.
- ST_WAIT_WARP (2): waits for Sub-Partition to accept warp.
- ST_NEXT_WARP (3): increments warp counter.

Logic:
- When block_issue_valid is high:
  block_accepted <= 1'b1;
  warp_cnt <= 0;
  linear_block_id = block_idx_x + (block_idx_y * 65535);
- Sub-Partition selection:
  Scans alloc[s].available_slots across all Sub-Partitions to pick the one with the most free slots (alloc_target_sp).
- Interface signals sent to warp_alloc_if:
  ```systemverilog
  alloc[alloc_target_sp].valid            <= 1'b1;
  alloc[alloc_target_sp].block_id         <= linear_block_id;
  alloc[alloc_target_sp].block_idx_x      <= block_idx_x;
  alloc[alloc_target_sp].block_idx_y      <= block_idx_y;
  alloc[alloc_target_sp].thread_id_start  <= warp_cnt * WARP_SIZE;
  alloc[alloc_target_sp].active_mask      <= 32'hFFFFFFFF;
  ```
- Handshake:
  When alloc[alloc_target_sp].ready is high, warp_cnt increments until warp_cnt == warps_per_block, then returns to ST_IDLE.

### 5. Sub-Partition Warp Context & SIMT Stack

Module: warp_context.sv (in sp_top.sv)

Data structures:
- warp_state[MAX_WARPS]: STATE_FREE (0), STATE_READY (1), STATE_STALL (2), STATE_DONE (3)
- warp_pc[MAX_WARPS]: 12-bit PC
- warp_mask[MAX_WARPS]: 32-bit active thread mask
- simt_stack[MAX_WARPS][4]: 4-entry stack storing {12-bit PC, 32-bit mask} (44 bits total)
- simt_sp[MAX_WARPS]: 3-bit stack pointer

1. Warp Allocation:
When alloc.valid is high and a free slot exists:
```systemverilog
warp_state[free_idx]           <= STATE_READY;
warp_pc[free_idx]              <= 12'd0;
warp_mask[free_idx]            <= alloc.active_mask;
warp_thread_id_start[free_idx] <= alloc.thread_id_start;
simt_sp[free_idx]              <= 3'd0;
```

2. Round-Robin Instruction Issue:
- Scans warp_state starting from rr_idx for a warp in STATE_READY.
- On match next_idx, outputs to issue_if:
  ```systemverilog
  issue.valid           <= 1'b1;
  issue.warp_id         <= next_idx;
  issue.pc              <= warp_pc[next_idx];
  issue.active_mask     <= warp_mask[next_idx];
  issue.thread_id_start <= warp_thread_id_start[next_idx];
  issue.block_idx_x/y   <= warp_block_idx_x/y[next_idx];
  
  // Pipeline interlock: locks the warp until write-back completes
  warp_state[next_idx]  <= STATE_STALL;
  rr_idx                <= (next_idx + 1) % MAX_WARPS;
  ```
- This locks the warp until write-back completes, preventing RAW hazards without needing forwarding logic.

3. SIMT Branch Divergence & Stack:
When ctx_wb.valid returns:
- Normal instruction:
  warp_pc[warp_id] <= ctx_wb.next_pc;
  warp_state[warp_id] <= STATE_READY;
- Divergent branch (ctx_wb.is_divergent == 1'b1):
  Push not-taken path:
  ```systemverilog
  simt_stack[warp_id][simt_sp] <= {warp_pc + 1, ctx_wb.not_taken_mask};
  simt_sp <= simt_sp + 1;
  ```
  Execute taken path:
  ```systemverilog
  warp_pc <= ctx_wb.next_pc;
  warp_mask <= ctx_wb.taken_mask;
  warp_state <= STATE_READY;
  ```
- Reconvergence (ctx_wb.is_sync == 1'b1):
  Pop from stack:
  ```systemverilog
  simt_sp <= simt_sp - 1;
  warp_pc <= simt_stack[warp_id][simt_sp - 1][43:32];
  warp_mask <= simt_stack[warp_id][simt_sp - 1][31:0];
  warp_state <= STATE_READY;
  ```
- Exit (ctx_wb.is_done == 1'b1):
  warp_state[warp_id] <= STATE_DONE;

### 6. Instruction Fetch, Decode & Vector Register File (VRF)

1. Fetch (fetch_decode.sv):
- Synchronous BRAM read (1-cycle delay):
  fetched_instr <= iram[issue.pc];
- Control signals delayed by 1 cycle using DFFs to match BRAM read latency:
  issue_valid_q <= issue.valid;
  issue_pc_q <= issue.pc;

2. Decode (fetch_decode.sv):
- Slices instruction fields:
  op = fetched_instr[31:24];
  rd = fetched_instr[23:19];
  rs1 = fetched_instr[18:14];
  rs2 = fetched_instr[13:9];
  imm = sign_extend(fetched_instr);
- Outputs to decode_if on next clock edge:
  decode.valid, decode.opcode, decode.rd, decode.rs1, decode.rs2, decode.imm

3. Vector Register File Read (vector_regfile.sv):
- Uses memory duplication with two identical BRAMs (ram_rs1, ram_rs2) to provide 2 read ports and 1 write port.
- Addresses:
  addr_rs1 = {decode.warp_id, decode.rs1};
  addr_rs2 = {decode.warp_id, decode.rs2};
- Synchronous read (1-cycle delay):
  rs1_data_read <= ram_rs1[addr_rs1];
  rs2_data_read <= ram_rs2[addr_rs2];
- Control signals delayed by 1 cycle (decode_*_q) to align with BRAM data output.
- Assembles operand_if:
  op.valid, op.rs1_data, op.rs2_data, op.imm, op.opcode, op.rd, op.warp_id, op.active_mask

### 7. Execution Pipeline (ALU Lanes & LSU)

1. SIMD ALU Lanes (sp_top.sv & alu_int32.sv):
Generated for K lanes (k = 0 .. NUM_LANES - 1):
- EX1 Stage (alu_int32.sv):
  Registers arithmetic outputs to map into DSP MREG registers and cut timing paths in half:
  ex1_add <= lane_rs1 + lane_rs2;
  ex1_sub <= lane_rs1 - lane_rs2;
  ex1_mul <= lane_rs1 * lane_rs2;
  Warp control latched: ex1_valid, ex1_opcode, ex1_rd, ex1_warp_id.
- EX2 Stage (alu_int32.sv):
  Multiplexes result based on opcode.
  S2R instruction: result = ex1_tid + lane_id (lane 0 gets tid, lane 1 gets tid+1, etc.).
  Condition code evaluation:
  next_n = result[31];
  next_z = (result == 0);
  next_p = (!next_n && !next_z);
  next_nzp[k] = {next_n, next_z, next_p};
- EX3 Stage (sp_top.sv):
  Packs lane results into vector write-back bus:
  ```systemverilog
  alu_wb.valid <= 1'b1;
  alu_wb.warp_id <= ex1_warp_id;
  alu_wb.rd <= ex1_rd;
  alu_wb.data[k*32 +: 32] <= lane_result[k];
  ```

2. PC & Branch Unit (pc.sv):
- Condition flags updated from ALU:
  warp_nzp[warp_id][k] <= next_nzp[k] (if active_mask[k] == 1);
- Branch condition evaluation:
  branch_cond = ex1_rd[2:0]; // {N, Z, P}
  branch_take[k] = ((branch_cond & warp_nzp[warp_id][k]) != 0) && active_mask[k];
  comb_taken_mask = {..., branch_take[1], branch_take[0]};
  comb_not_taken_mask = active_mask & ~comb_taken_mask;
- Resolution:
  If both masks != 0: divergence detected, next_pc = pc + imm, taken path executes first.
  If all active take branch: next_pc = pc + imm.
  If not taken: next_pc = pc + 1.
  Drives ctx_alu_wb.valid, next_pc, is_divergent, is_sync, is_done.

3. Load/Store Unit (lsu.sv):
- Decoupled from ALU:
  When opcode is LDR or STR:
  l1_req_valid <= 1'b1;
  l1_req_addr <= rs1_data + imm;
  l1_req_wdata <= rs2_data;
  LSU enters wait state while warp is stalled.
- When L1 cache returns l1_rsp_valid:
  lsu_wb.valid <= 1'b1;
  lsu_wb.data <= l1_rsp_rdata;
  ctx_lsu_wb.valid <= 1'b1;
  ctx_lsu_wb.next_pc <= pc + 1;

### 8. Write-Back & Context Resumption

1. Write-Back Arbiter (sp_top.sv):
- LSU has priority over ALU to prevent cache pipeline stalls:
  ```systemverilog
  assign wb.valid     = lsu_wb.valid ? lsu_wb.valid : alu_wb.valid;
  assign wb.warp_id   = lsu_wb.valid ? lsu_wb.warp_id : alu_wb.warp_id;
  assign wb.rd        = lsu_wb.valid ? lsu_wb.rd : alu_wb.rd;
  assign wb.data      = lsu_wb.valid ? lsu_wb.data : alu_wb.data;
  assign ctx_wb.valid = lsu_wb.valid ? ctx_lsu_wb.valid : ctx_alu_wb.valid;
  assign ctx_wb.next_pc = lsu_wb.valid ? ctx_lsu_wb.next_pc : ctx_alu_wb.next_pc;
  ```

2. VRF Write (vector_regfile.sv):
- Synchronous write to both memory banks on posedge clk:
  addr_wb = {wb.warp_id, wb.rd};
  ram_rs1[addr_wb] <= wb.data;
  ram_rs2[addr_wb] <= wb.data;

3. Warp Unlock (warp_context.sv):
- ctx_wb.valid arrives at warp_context:
  warp_pc[warp_id] <= ctx_wb.next_pc;
  warp_state[warp_id] <= STATE_READY;
- The warp is now unlocked and can be selected by the scheduler on the next cycle.

### 9. Memory Hierarchy (L1 & L2 Cache)

1. L1 Cache (l1_cache.sv):
- 2KB Direct-Mapped, Write-Through, 32 bytes per line.
- Address breakdown: Tag [31:11] (21 bits) | Index [10:5] (6 bits) | Offset [4:0] (5 bits).
- Read Hit: returns data from BRAM in 1 cycle.
- Read Miss: sends request to L2 cache (l2_req_valid), waits for l2_rsp_valid, updates data_ram, and returns data to LSU.
- Write: sends write to L2 cache and invalidates local line (valid_ram[index] <= 0) to avoid read-modify-write complexity.

2. L2 Cache (l2_cache.sv):
- 16KB Direct-Mapped, Write-Through, 32 bytes per line.
- Parameterized with NUM_PORTS to serve all SMs.
- Round-robin arbiter rotates through SM requests.
- Read Hit: returns 256-bit line to the requesting SM.
- Read Miss / Write: drives AXI4-Full master (m_axi_gmem) to DDR3 controller (MIG). When DDR3 transaction completes, returns response to the requesting SM.

### 10. Completion Handshake & Host Interrupt

1. Warp Exit:
- When an instruction executes OP_EXIT (0xFF), pc.sv sets ctx_alu_wb.is_done <= 1'b1.
- warp_context.sv sets warp_state[warp_id] <= STATE_DONE.

2. SM Slot Recovery:
- As warps finish, available_warp_slots increases back to MAX_WARPS.

3. TBS Grid Done:
- In STATE_WAIT_DONE, TBS detects all thread blocks have been dispatched and all SMs have all slots free.
- TBS asserts grid_done <= 1'b1.

4. Firmware & Host Notification:
- gpc_control_register.sv latches grid_done_status into REG_INT_STATUS (0x1000_0004) bit 0.
- PicoRV32 firmware detects completion:
  ```c
  while ((REG_INT_STATUS & 0x1) == 0);
  MAILBOX->num_elements = 0x2; // Done
  __builtin_trap();
  ```
- Trap signal triggers gpu_top.sv to assert usr_irq_req to PCIe XDMA.
- Host Linux driver handles the MSI interrupt and returns compute results to user space.
