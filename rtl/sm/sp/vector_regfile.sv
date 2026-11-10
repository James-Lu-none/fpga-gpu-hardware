`timescale 1ns / 1ps
// SIMT vector register file: two read ports and one masked write-back port.
// Each lane's storage supplies ready and two synchronous read outputs. R0 reads
// as zero and ignores write-back. BRAM read and operand capture take two
// cycles; only valid is reset, while RAM and payload registers retain data.

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

    // One register entry per warp/register pair.
    localparam RAM_DEPTH = MAX_WARPS * NUM_REGS;

    // The storage implementation selects replicated FPGA RAM or a shared ASIC
    // macro. A read is accepted only when every lane's storage is available.
    // When executing BR (0xC0), route decode.rd to rs1 read port so op.rs1_data
    // contains the predicate register for direct register-based branching.
    wire [4:0] eff_rs1 = (decode.opcode == 8'hC0) ? decode.rd : decode.rs1;
    wire [7:0] addr_rs1 = {decode.warp_id, eff_rs1};
    wire [7:0] addr_rs2 = {decode.warp_id, decode.rs2};
    wire [7:0] addr_wb = {wb.warp_id, wb.rd};

    wire [DATA_W-1:0] rs1_data_read;
    wire [DATA_W-1:0] rs2_data_read;
    wire [NUM_LANES-1:0] lane_read_ready;
    assign decode.ready = rst_n && (&lane_read_ready);
    wire read_accept = decode.valid && decode.ready;

    // Pipeline registers for control signals
    reg [7:0] addr_rs1_q, addr_rs2_q;
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

    for (genvar lane = 0; lane < NUM_LANES; lane++) begin : gen_lane_ram
        wire lane_write_enable = wb.valid && (wb.rd != 5'd0) && wb.mask[lane];
        vector_regfile_ram #(.DEPTH(RAM_DEPTH), .ADDR_W(8)) memory (
            .clk(clk), .write_enable(lane_write_enable),
            .write_address(addr_wb), .write_data(wb.data[lane*32 +: 32]),
            .read_enable(read_accept), .read_ready(lane_read_ready[lane]),
            .read_address1(addr_rs1), .read_data1(rs1_data_read[lane*32 +: 32]),
            .read_address2(addr_rs2), .read_data2(rs2_data_read[lane*32 +: 32])
        );
    end

    // Only valid uses asynchronous reset. Mixing unreset payload registers
    // into this block produces Vivado Synth 8-7137 set/reset-priority warnings.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) decode_valid_q <= 1'b0;
        else decode_valid_q <= read_accept;
    end

    // Match the synchronous BRAM read with one cycle of address/metadata.
    // Hold metadata while decode is blocked; only accepted reads advance it.
    always @(posedge clk) begin
        if (read_accept) begin
            addr_rs1_q <= addr_rs1;
            addr_rs2_q <= addr_rs2;
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

    // Operand stage: isolate BRAM clock-to-output and R0 selection from
    // combinational ALU/DSP execution. Data and metadata advance together.
    // Only valid needs reset; invalid operand contents are never consumed.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) op.valid <= 1'b0;
        else op.valid <= decode_valid_q;
    end
    always @(posedge clk) begin
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
        op.rs1_data <= (addr_rs1_q[4:0] == 0) ? '0 : rs1_data_read;
        op.rs2_data <= (addr_rs2_q[4:0] == 0) ? '0 : rs2_data_read;
    end

endmodule
