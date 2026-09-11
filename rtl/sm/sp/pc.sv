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

import gpu_pkg::*;

module pc (
    input wire clk,
    input wire rst_n,

    // Operand Interface
    operand_if.slave op,

    // From ALU
    input wire alu_updates_nzp,
    input wire [2:0] next_nzp0,
    input wire [2:0] next_nzp1,
    input wire is_exit,
    input wire is_branch,
    input wire is_sync,

    // Context Write-Back (Signals sent to the warp_context scheduler)
    ctx_wb_if.master ctx_wb
);

    // NZP Registers (Condition Codes per Warp, Per Lane)
    // [2]=N, [1]=Z, [0]=P
    reg [2:0] warp_nzp [0:MAX_WARPS-1][0:31];

    integer i, j;
    initial begin
        for (i=0; i<MAX_WARPS; i=i+1) begin
            for (j=0; j<32; j=j+1) begin
                warp_nzp[i][j] = 3'b000;
            end
        end
    end

    // Execution Stage 1: Pipeline Registers for Operand Data
    reg ex1_valid;
    reg [3:0] ex1_warp_id;
    reg [4:0] ex1_rd;
    reg [31:0] ex1_imm;
    reg [31:0] ex1_active_mask;
    reg [11:0] ex1_pc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex1_valid <= 1'b0;
        end else begin
            ex1_valid <= op.valid;
            ex1_warp_id <= op.warp_id;
            ex1_rd <= op.rd;
            ex1_imm <= op.imm;
            ex1_active_mask <= op.active_mask;
            ex1_pc <= op.pc;
        end
    end

    // Execution Stage 2: Branch Evaluator (Combinational)
    wire [2:0] branch_cond = ex1_rd[2:0];
    wire branch_take0 = ((branch_cond & warp_nzp[ex1_warp_id][0]) != 3'b000) && ex1_active_mask[0];
    wire branch_take1 = ((branch_cond & warp_nzp[ex1_warp_id][1]) != 3'b000) && ex1_active_mask[1];
    
    wire [31:0] comb_taken_mask = {30'd0, branch_take1, branch_take0};
    wire [31:0] comb_not_taken_mask = ex1_active_mask & ~comb_taken_mask;

    // Execution Stage 3: Write-Back signals
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctx_wb.valid <= 1'b0;
            ctx_wb.warp_id <= 4'd0;
            ctx_wb.next_pc <= 12'd0;
            ctx_wb.is_done <= 1'b0;
            ctx_wb.taken_mask <= 32'd0;
            ctx_wb.not_taken_mask <= 32'd0;
            ctx_wb.is_divergent <= 1'b0;
            ctx_wb.is_sync <= 1'b0;
        end else begin
            ctx_wb.valid <= 1'b0;
            ctx_wb.is_divergent <= 1'b0;
            ctx_wb.is_sync <= 1'b0;

            // Wait for ex1_valid (since ALU signals also arrive in EX2 based on ex1_valid)
            if (ex1_valid) begin
                // 1. Update NZP Register
                if (alu_updates_nzp) begin
                    if (ex1_active_mask[0]) warp_nzp[ex1_warp_id][0] <= next_nzp0;
                    if (ex1_active_mask[1]) warp_nzp[ex1_warp_id][1] <= next_nzp1;
                end

                // 2. PC & State Update
                ctx_wb.valid <= 1'b1;
                ctx_wb.warp_id <= ex1_warp_id;
                ctx_wb.is_done <= is_exit;
                
                // Branch & Sync Logic (Divergence Tester)
                if (is_sync) begin
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

endmodule
