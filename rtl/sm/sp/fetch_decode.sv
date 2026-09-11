`timescale 1ns / 1ps
// SM Fetch & Decode Stage (Programmable GPU)
// Fetches instructions from I-RAM and decodes the custom 32-bit ISA.

import gpu_pkg::*;

module fetch_decode (
    input wire clk,
    input wire rst_n,

    // Instruction Load Interface (From GPC)
    input wire iram_we,
    input wire [11:0] iram_waddr,
    input wire [31:0] iram_wdata,

    // Issue Interface (From Warp Context)
    issue_if.slave issue,

    // Decode Output Interface (To Execution Pipeline)
    decode_if.master decode
);

    // 1. Instruction Memory (I-RAM)
    (* ram_style = "block" *) reg [31:0] iram [0:IRAM_DEPTH-1];
    reg [31:0] fetched_instr;

    always @(posedge clk) begin
        if (iram_we) begin
            iram[iram_waddr] <= iram_wdata;
        end
        // Implicit 1-cycle latency BRAM read
        fetched_instr <= iram[issue.pc];
    end

    reg issue_valid_q;
    reg [$clog2(MAX_WARPS)-1:0] issue_warp_id_q;
    reg [11:0] issue_pc_q;
    reg [31:0] issue_active_mask_q;
    reg [15:0] issue_block_idx_x_q;
    reg [15:0] issue_block_idx_y_q;
    reg [15:0] issue_thread_id_start_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_valid_q <= 1'b0;
        end else begin
            issue_valid_q <= issue.valid;
            issue_warp_id_q <= issue.warp_id;
            issue_pc_q <= issue.pc;
            issue_active_mask_q <= issue.active_mask;
            issue_block_idx_x_q <= issue.block_idx_x;
            issue_block_idx_y_q <= issue.block_idx_y;
            issue_thread_id_start_q <= issue.thread_id_start;
        end
    end

    // 3. Instruction Decode Stage
    // Formats:
    // R-Type: [31:24] Opcode | [23:19] Rd | [18:14] Rs1 | [13:9] Rs2 | [8:0] Unused
    // I-Type: [31:24] Opcode | [23:19] Rd | [18:14] Rs1 | [13:0] Imm14
    // J-Type: [31:24] Opcode | [23:19] Cond| [18:0] Imm19
    
    wire [7:0] op = fetched_instr[31:24];
    wire [4:0] rd = fetched_instr[23:19];
    wire [4:0] rs1 = fetched_instr[18:14];
    wire [4:0] rs2 = fetched_instr[13:9];
    wire [13:0] imm14 = fetched_instr[13:0];
    wire [18:0] imm19 = fetched_instr[18:0];
    
    wire is_j_type = (op == 8'hC0);
    wire is_imm_inst = (op >= 8'h80);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decode.valid <= 1'b0;
        end else begin
            decode.valid <= issue_valid_q;
            
            decode.warp_id <= issue_warp_id_q;
            decode.pc <= issue_pc_q;
            decode.active_mask <= issue_active_mask_q;
            decode.block_idx_x <= issue_block_idx_x_q;
            decode.block_idx_y <= issue_block_idx_y_q;
            decode.thread_id_start <= issue_thread_id_start_q;
            
            if (issue_valid_q) begin
                decode.opcode <= op;
                decode.rd <= rd;
                decode.rs1 <= rs1;
                decode.rs2 <= rs2;
                decode.is_imm <= is_imm_inst;
                
                // Sign-extend immediate based on instruction type
                if (is_j_type) begin
                    decode.imm <= {{13{imm19[18]}}, imm19};
                end else begin
                    decode.imm <= {{18{imm14[13]}}, imm14};
                end
            end
        end
    end

endmodule
