`timescale 1ns / 1ps
// 32-bit Integer ALU Lane (Single SIMD Lane)
//
// Represents a single 32-bit SIMD Execution Lane.
// Multiple instances of this module are generated across the vector datapath.
// Currently supports integer arithmetic (ADD, SUB, MUL) and logical operations.
//
// Pipeline Architecture:
// - Execution Stage 1: Pipelined arithmetic operations (ADD, SUB, MUL) to break DSP critical paths.
// - Execution Stage 2: MUXing, Condition Codes (NZP), and S2R resolution.
// originally, we did too much work in the same clock cycle
// 1. decode opcode 
// 2. perform arithmetic execution
// 3. send result to comparator to check if result is zero or negative and generate NZP code 
// 4. send to PC module 
// 5. write to warp_nzp_reg
// so we separate arithmetic execution from other pipeline stages. 
// This is because arithmetic execution (especially multiplication) is very time consuming and will make the critical path too long.
// So we seperate Arithmetic Execution and NZP computation into two pipeline stages. 

import gpu_pkg::*;

module alu_int32 #(
    parameter LANE_INDEX = 0
)(
    input wire clk,
    input wire rst_n,

    // Instruction & Control
    input wire        valid,
    input wire [7:0]  opcode,
    input wire [31:0] imm,

    // 32-bit Lane Operands
    input wire [31:0] rs1_data,
    input wire [31:0] rs2_data,

    // Thread Context (for Special Register S2R)
    input wire [4:0]  lane_id,
    input wire [15:0] thread_id_start,
    input wire [15:0] block_idx_x,
    input wire [15:0] block_idx_y,

    // Lane Outputs
    output reg [31:0] result,
    output wire [2:0] next_nzp
);

    // Opcodes Definition
    localparam OP_ADD = 8'h01;
    localparam OP_SUB = 8'h02;
    localparam OP_MUL = 8'h03;
    localparam OP_CMP = 8'h04;
    localparam OP_ADDI = 8'h81;
    localparam OP_S2R = 8'hB0;
    localparam OP_BR = 8'hC0;
    localparam OP_SYNC = 8'hE0;
    localparam OP_EXIT = 8'hFF;

    // Execution Stage 1: Arithmetic Execution (Pipelined to break DSP critical path)
    reg [31:0] ex1_add;
    reg [31:0] ex1_sub;
    reg [31:0] ex1_mul;

    reg        ex1_valid;
    reg [7:0]  ex1_opcode;
    reg [31:0] ex1_imm;
    reg [15:0] ex1_tid, ex1_bid_x, ex1_bid_y;
    reg [4:0]  ex1_lane_id;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex1_valid   <= 1'b0;
            ex1_opcode  <= 8'd0;
            ex1_imm     <= 32'd0;
            ex1_tid     <= 16'd0;
            ex1_lane_id <= 5'd0;
            ex1_bid_x   <= 16'd0;
            ex1_bid_y   <= 16'd0;
            ex1_add     <= 32'd0;
            ex1_sub     <= 32'd0;
            ex1_mul     <= 32'd0;
        end else begin
            ex1_valid   <= valid;
            ex1_opcode  <= opcode;
            ex1_imm     <= imm;
            ex1_tid     <= thread_id_start;
            ex1_lane_id <= lane_id;
            ex1_bid_x   <= block_idx_x;
            ex1_bid_y   <= block_idx_y;

            // Let Vivado infers DSP/Adder registers directly
            ex1_add     <= rs1_data + rs2_data;
            ex1_sub     <= rs1_data - rs2_data;
            ex1_mul     <= rs1_data * rs2_data;
        end
    end

    // Execution Stage 2: MUXing, Special Registers & NZP Evaluation
    reg _eval_nzp;

    always @(*) begin
        result    = 32'd0;
        _eval_nzp = 1'b0;

        case (ex1_opcode)
            OP_ADD, OP_ADDI: begin
                result    = ex1_add;
                _eval_nzp = 1'b1;
            end
            OP_SUB, OP_CMP: begin
                result    = ex1_sub;
                _eval_nzp = 1'b1;
            end
            OP_MUL: begin
                result    = ex1_mul;
                _eval_nzp = 1'b0; // NZP disabled for MUL
            end
            OP_S2R: begin
                case (ex1_imm)
                    32'd0:   result = {16'd0, ex1_tid} + {27'd0, ex1_lane_id};
                    32'd1:   result = 32'd0;
                    32'd2:   result = {16'd0, ex1_bid_x};
                    32'd3:   result = {16'd0, ex1_bid_y};
                    default: result = 32'd0;
                endcase
            end
            default: ;
        endcase
    end

    // Timing Optimization: Only ADD/SUB/CMP evaluate NZP
    wire [31:0] nzp_eval = (_eval_nzp) ? result : 32'hFFFFFFFF;
    wire next_n = nzp_eval[31];
    wire next_z = (nzp_eval == 32'd0);
    wire next_p = (!next_n && !next_z);
    assign next_nzp = {next_n, next_z, next_p};

endmodule
