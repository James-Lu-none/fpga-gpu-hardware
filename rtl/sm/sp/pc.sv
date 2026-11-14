`timescale 1ns / 1ps
// PC (Program Counter & Branch Control Unit)
//
// This module evaluates branch conditions and computes the next Program 
// Counter (PC) for the warp. It tracks the Negative/Zero/Positive (NZP) 
// condition codes for each thread (lane) individually.
//
// Branch Divergence:
// If a branch condition evaluates to true for some threads but false for 
// others, a "Divergence" occurs. The PC module generates a `taken_mask` 
// and a `not_taken_mask` to split the warp.

`include "gpu_defines.vh"

module pc (
    input wire clk,
    input wire rst_n,

    // Operand Interface
    operand_if.slave op,

    // From ALU
    input wire is_exit,
    input wire is_branch,
    input wire is_sync,
    input wire is_ssy,

    // Context Write-Back (Signals sent to the warp_context scheduler)
    ctx_wb_if.master ctx_wb
);

    // Align context retirement with the two-cycle ALU pipeline.
    reg [0:0] op_valid_q;
    reg [7:0] op_opcode_q;
    reg [$clog2(`MAX_WARPS)-1:0] op_warp_id_q;
    reg [4:0] op_rd_q;
    reg [31:0] op_imm_q;
    reg [31:0] op_active_mask_q;
    reg [11:0] op_pc_q;
    reg [`WARP_DATA_W-1:0] op_rs1_data_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) op_valid_q <= 0;
        else op_valid_q <= op.valid;
    end
    always @(posedge clk) begin
        op_opcode_q <= op.opcode;
        op_warp_id_q <= op.warp_id;
        op_rd_q <= op.rd;
        op_imm_q <= op.imm;
        op_active_mask_q <= op.active_mask;
        op_pc_q <= op.pc;
        op_rs1_data_q <= op.rs1_data;
    end

    // Execution Stage 1: Pipeline Registers for Operand Data
    reg ex1_valid;
    reg [7:0] ex1_opcode;
    reg [$clog2(`MAX_WARPS)-1:0] ex1_warp_id;
    reg [4:0] ex1_rd;
    reg [31:0] ex1_imm;
    reg [31:0] ex1_active_mask;
    reg [11:0] ex1_pc;
    reg [`WARP_DATA_W-1:0] ex1_rs1_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex1_valid <= 1'b0;
            ex1_opcode <= 8'd0;
            ex1_warp_id <= '0;
            ex1_rd <= 5'd0;
            ex1_imm <= 32'd0;
            ex1_active_mask <= 32'd0;
            ex1_pc <= 12'd0;
            ex1_rs1_data <= '0;
        end else begin
            ex1_valid <= op_valid_q;
            ex1_opcode <= op_opcode_q;
            ex1_warp_id <= op_warp_id_q;
            ex1_rd <= op_rd_q;
            ex1_imm <= op_imm_q;
            ex1_active_mask <= op_active_mask_q;
            ex1_pc <= op_pc_q;
            ex1_rs1_data <= op_rs1_data_q;
        end
    end

    // Execution Stage 2: Branch Evaluator (Combinational)
    wire is_lsu = (ex1_opcode == 8'hA0 || ex1_opcode == 8'hA1);

    // Register-based branching:
    // If rd == 0 (R0): unconditional branch (all active lanes take the branch).
    // If rd != 0 (R1..R31): lane l branches if VRF[rd][l] != 0.
    wire [`NUM_LANES-1:0] branch_take;
    for (genvar l = 0; l < `NUM_LANES; l = l + 1) begin : gen_branch_take
        wire lane_cond = (ex1_rd == 5'd0) ? 1'b1 : (ex1_rs1_data[l*32 +: 32] != 32'd0);
        assign branch_take[l] = lane_cond && ex1_active_mask[l];
    end
    
    wire [31:0] comb_taken_mask = {{(32-`NUM_LANES){1'b0}}, branch_take};
    wire [31:0] comb_not_taken_mask = ex1_active_mask & ~comb_taken_mask;

    // Execution Stage 3: Write-Back signals
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctx_wb.valid <= 1'b0;
            ctx_wb.warp_id <= '0;
            ctx_wb.next_pc <= 12'd0;
            ctx_wb.is_done <= 1'b0;
            ctx_wb.taken_mask <= 32'd0;
            ctx_wb.not_taken_mask <= 32'd0;
            ctx_wb.is_divergent <= 1'b0;
            ctx_wb.is_sync <= 1'b0;
            ctx_wb.is_ssy <= 1'b0;
            ctx_wb.target_pc <= 12'd0;
        end else begin
            ctx_wb.valid <= 1'b0;
            ctx_wb.is_divergent <= 1'b0;
            ctx_wb.is_sync <= 1'b0;
            ctx_wb.is_ssy <= 1'b0;

            // Wait for ex1_valid (since ALU signals also arrive in EX2 based on ex1_valid)
            if (ex1_valid) begin
                // PC & State Update (Only for non-LSU instructions; LSU handles its own ctx_wb)
                if (!is_lsu) begin
                    ctx_wb.valid <= 1'b1;
                    ctx_wb.warp_id <= ex1_warp_id;
                    ctx_wb.is_done <= is_exit;
                    
                    // Branch & Sync & SSY Logic (Divergence Tester)
                    if (is_ssy) begin
                        ctx_wb.is_ssy <= 1'b1;
                        ctx_wb.next_pc <= ex1_pc + 12'd1;
                        ctx_wb.target_pc <= ex1_pc + ex1_imm[11:0];
                    end else if (is_sync) begin
                        ctx_wb.is_sync <= 1'b1;
                        ctx_wb.next_pc <= ex1_pc + 12'd1;
                    end else if (is_branch) begin
                        if (comb_taken_mask != 32'd0 && comb_not_taken_mask != 32'd0) begin
                            // Divergence!
                            ctx_wb.is_divergent <= 1'b1;
                            ctx_wb.taken_mask <= comb_taken_mask;
                            ctx_wb.not_taken_mask <= comb_not_taken_mask;
                            ctx_wb.next_pc <= ex1_pc + ex1_imm[11:0]; // Taken path executes first
                        end else if (comb_taken_mask != 32'd0) begin
                            // All active threads take the branch (No Divergence)
                            ctx_wb.next_pc <= ex1_pc + ex1_imm[11:0];
                        end else begin
                            // All active threads don't take the branch
                            ctx_wb.next_pc <= ex1_pc + 12'd1;
                        end
                    end else begin
                        // Normal execution
                        ctx_wb.next_pc <= ex1_pc + 12'd1;
                    end
                end
            end
        end
    end

endmodule
