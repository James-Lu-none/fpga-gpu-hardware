`timescale 1ns / 1ps
// SIMT vector register file: two read ports and one masked write-back port.
// Each lane has odd/even banks, each holding half the register addresses.
// R0 reads as zero and ignores write-back.
// BRAM read and operand capture take two cycles; only valid is reset, 
// while RAM and payload registers retain data.

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
    localparam BANK_DEPTH = MAX_WARPS * (NUM_REGS / 2);

    // Two distinct nonzero sources must have opposite parity. The compiler
    // repairs conflicts; R0 is bypassed and identical sources are broadcast.
    // When executing BR (0xC0), route decode.rd to rs1 read port so op.rs1_data
    // contains the predicate register for direct register-based branching.
    wire uses_two_sources = (decode.opcode >= 8'h01 && decode.opcode <= 8'h08) || decode.opcode == 8'hA1;
    wire uses_rs1 = uses_two_sources || decode.opcode == 8'h81 || decode.opcode == 8'hA0 || decode.opcode == 8'hC0;
    wire [4:0] eff_rs1 = !uses_rs1 ? 5'd0 : (decode.opcode == 8'hC0 ? decode.rd : decode.rs1);
    wire [4:0] eff_rs2 = uses_two_sources ? decode.rs2 : 5'd0;
    wire [7:0] addr_rs1 = {decode.warp_id, eff_rs1};
    wire [7:0] addr_rs2 = {decode.warp_id, eff_rs2};
    wire [6:0] addr_wb = {wb.warp_id, wb.rd[4:1]};
    wire [6:0] even_address = {decode.warp_id, ((!eff_rs1[0] && eff_rs1 != 0) ? eff_rs1[4:1] : eff_rs2[4:1])};
    wire [6:0] odd_address = {decode.warp_id, (eff_rs1[0] ? eff_rs1[4:1] : eff_rs2[4:1])};

    wire [DATA_W-1:0] even_data_read;
    wire [DATA_W-1:0] odd_data_read;

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && decode.valid && eff_rs1 != 0 && eff_rs2 != 0 &&
            eff_rs1 != eff_rs2 && eff_rs1[0] == eff_rs2[0])
            $fatal(1, "VRF bank conflict: warp=%0d opcode=%h rs1=R%0d rs2=R%0d",
                   decode.warp_id, decode.opcode, eff_rs1, eff_rs2);
    end
`endif

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
        vector_regfile_ram #(.DEPTH(BANK_DEPTH), .ADDR_W(7)) u_even (
            .clk(clk), .write_enable(lane_write_enable && !wb.rd[0]),
            .write_address(addr_wb), .write_data(wb.data[lane*32 +: 32]),
            .read_address(even_address), .read_data(even_data_read[lane*32 +: 32])
        );
        vector_regfile_ram #(.DEPTH(BANK_DEPTH), .ADDR_W(7)) u_odd (
            .clk(clk), .write_enable(lane_write_enable && wb.rd[0]),
            .write_address(addr_wb), .write_data(wb.data[lane*32 +: 32]),
            .read_address(odd_address), .read_data(odd_data_read[lane*32 +: 32])
        );
    end

    // Only valid uses asynchronous reset. Mixing unreset payload registers
    // into this block produces Vivado Synth 8-7137 set/reset-priority warnings.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) decode_valid_q <= 1'b0;
        else decode_valid_q <= decode.valid;
    end

    // Match the synchronous BRAM read with one cycle of address/metadata.
    // Payload may advance during reset; cleared valid prevents its use.
    always @(posedge clk) begin
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
        op.rs1_data <= (addr_rs1_q[4:0] == 0) ? '0 : (addr_rs1_q[0] ? odd_data_read : even_data_read);
        op.rs2_data <= (addr_rs2_q[4:0] == 0) ? '0 : (addr_rs2_q[0] ? odd_data_read : even_data_read);
    end

endmodule
