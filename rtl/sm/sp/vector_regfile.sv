`timescale 1ns / 1ps
// Streaming Multiprocessor (SM) - Vector Register File (VRF)
//
// Unlike a scalar CPU register that holds a single value (e.g. 32-bit), a GPU 
// register holds a "vector" of values, one for each thread in the warp. 
// For example, R1 here contains [Thread1's R1, Thread0's R1].
//
// rs1: Register Source 1 (The first operand to read, e.g., R2 in ADD R1, R2, R3)
// rs2: Register Source 2 (The second operand to read, e.g., R3 in ADD R1, R2, R3)
// rd: Register Destination (The target register to write, e.g., R1 in ADD R1, R2, R3)
// wb: Write-Back (The action of writing the ALU/LSU computed result back to rd)
//
// Current supported instruction needs to read two sources (rs1, rs2) at most and write one 
// result (rd) simultaneously. However, FPGA BRAMs typically only have 2 ports total 
// (e.g., 1 read + 1 write, or 2 reads). 
// To solve this, we use the "Memory Duplication" technique: we instantiate two 
// identical BRAMs (`ram_rs1` and `ram_rs2`).
// - The 2 Reads: We use port A of `ram_rs1` to read `rs1`, and port A of `ram_rs2` to read `rs2`.
// - The 1 Write: We use port B of both `ram_rs1` and `ram_rs2` to write the `wb_data` 
//   simultaneously, ensuring both BRAMs always hold the exact same identical data.
//
// # All 32 registers for each thread in each warp are uninitialized (or zero) before execution.
// But in order to let the alu (thread) know its ID, the Hardware will preload the thread's ID 
// (e.g., threadIdx.x and blockIdx.x) into register R1 and R2 before the fetch_decode
// receives the first instruction.
//
// Manages the registers for all resident warps.
// Uses duplicated BRAMs to provide 2 Read Ports and 1 Write Port.

import gpu_pkg::*;

module vector_regfile (
    input wire clk,
    input wire rst_n,

    // Decode Interface (From fetch_decode)
    decode_if.slave decode,
    // Operand Interface (To sm_execution_pipe)
    operand_if.master op,
    
    // Write-Back Interface (From sm_execution_pipe)
    wb_if.slave wb
);

    // Total registers = 16 warps * 32 regs = 512 entries
    localparam RAM_DEPTH = MAX_WARPS * NUM_REGS;

    // To get 2R1W from FPGA BRAMs, we duplicate the memory.
    // ram_rs1 is exclusively used to read the rs1 operand.
    // ram_rs2 is exclusively used to read the rs2 operand.
    // Both are updated identically during a write-back.
    (* ram_style = "block" *) reg [DATA_W-1:0] ram_rs1 [0:RAM_DEPTH-1];
    (* ram_style = "block" *) reg [DATA_W-1:0] ram_rs2 [0:RAM_DEPTH-1];

    wire [7:0] addr_rs1 = {decode.warp_id, decode.rs1};
    wire [7:0] addr_rs2 = {decode.warp_id, decode.rs2};
    wire [7:0] addr_wb = {wb.warp_id, wb.rd};

    reg [DATA_W-1:0] rs1_data_read;
    reg [DATA_W-1:0] rs2_data_read;

    // Pipeline registers for control signals
    reg decode_valid_q;
    reg [$clog2(MAX_WARPS)-1:0] decode_warp_id_q;
    reg [11:0] decode_pc_q;
    reg [31:0] decode_active_mask_q;
    reg [7:0] decode_opcode_q;
    reg [4:0] decode_rd_q;
    reg [31:0] decode_imm_q;
    reg decode_is_imm_q;
    reg [15:0] decode_block_idx_x_q;
    reg [15:0] decode_block_idx_y_q;
    reg [15:0] decode_thread_id_start_q;

    // Synchronous Read and Write
    always @(posedge clk) begin
        // Write Port (Write-back from ALU/LSU)
        // This handles the "1 Write". When the execution pipeline finishes a computation,
        // it provides the result (wb_data) and the destination register (wb_rd).
        // We write this data into BOTH ram_rs1 and ram_rs2 at the same time to keep them synced.
        if (wb.valid && (wb.rd != 5'd0)) begin // Assuming R0 is read-only zero or normal reg
            // alus will write back in format {alu1_out, alu0_out}
            ram_rs1[addr_wb] <= wb.data;
            ram_rs2[addr_wb] <= wb.data;
        end

        // Read Ports (1 cycle latency)
        // This handles the "2 Reads". We supply the addresses (addr_rs1, addr_rs2) to 
        // the BRAMs, and they will output the data (rs1_data_read, rs2_data_read) on the next cycle.
        rs1_data_read <= ram_rs1[addr_rs1];
        rs2_data_read <= ram_rs2[addr_rs2];
    end

    // Pipeline Alignment:
    // Since BRAM on FPGA has a 1-cycle read latency, we must delay all control 
    // signals (opcode, pc, etc.) by 1 cycle using D-Flip-Flops (_q). 
    // This ensures that when the BRAM outputs the register data on the next cycle, 
    // the control signals arrive at the ALU at the exact same time.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decode_valid_q <= 1'b0;
        end else begin
            decode_valid_q <= decode.valid;
            decode_warp_id_q <= decode.warp_id;
            decode_pc_q <= decode.pc;
            decode_active_mask_q <= decode.active_mask;
            decode_opcode_q <= decode.opcode;
            decode_rd_q <= decode.rd;
            decode_imm_q <= decode.imm;
            decode_is_imm_q <= decode.is_imm;
            decode_block_idx_x_q <= decode.block_idx_x;
            decode_block_idx_y_q <= decode.block_idx_y;
            decode_thread_id_start_q <= decode.thread_id_start;
        end
    end

    // Operand Formatting (Output to ALU)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op.valid <= 1'b0;
        end else begin
            op.valid <= decode_valid_q;
            
            if (decode_valid_q) begin
                op.warp_id <= decode_warp_id_q;
                op.pc <= decode_pc_q;
                op.active_mask <= decode_active_mask_q;
                op.block_idx_x <= decode_block_idx_x_q;
                op.block_idx_y <= decode_block_idx_y_q;
                op.thread_id_start <= decode_thread_id_start_q;
                op.opcode <= decode_opcode_q;
                op.rd <= decode_rd_q;
                op.imm <= decode_imm_q;
                op.is_imm <= decode_is_imm_q;
                
                op.rs1_data <= rs1_data_read;
                op.rs2_data <= rs2_data_read;
            end
        end
    end

endmodule
