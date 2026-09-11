`timescale 1ns / 1ps

// This module maintains the state (PC, Active Mask, Status) of up to 16 resident warps.
// 
// SIMT Stack (Branch Divergence Stack):
// To handle IF/ELSE branches where threads in the same warp diverge, this 
// module implements a hardware stack. It pushes the 'Not Taken' path onto 
// the stack and follows the 'Taken' path. When a 'SYNC' instruction is hit, 
// it pops the stack to resume the other path. ('if' branch first, 'else' branch second)

import gpu_pkg::*;

module warp_context (
    input wire clk,
    input wire rst_n,

    // Allocation Interface (From GPU Top Scheduler)
    warp_alloc_if.slave alloc,

    // Issue Interface (To Fetch/Decode Stage)
    issue_if.master issue,
    
    // Feedback Interface (From Execution Pipeline)
    ctx_wb_if.slave ctx_wb
);

    // Warp States
    localparam STATE_FREE = 2'd0;
    localparam STATE_READY = 2'd1;
    localparam STATE_STALL = 2'd2; // E.g., waiting for memory (for future use)
    localparam STATE_DONE = 2'd3;

    // Context RAM Arrays
    reg [1:0] warp_state [0:MAX_WARPS-1];
    reg [11:0] warp_pc [0:MAX_WARPS-1];
    reg [31:0] warp_mask [0:MAX_WARPS-1];
    reg [15:0] warp_block_id [0:MAX_WARPS-1];
    reg [15:0] warp_block_idx_x [0:MAX_WARPS-1];
    reg [15:0] warp_block_idx_y [0:MAX_WARPS-1];
    reg [15:0] warp_thread_id_start [0:MAX_WARPS-1];

    // SIMT Stack (Active Mask Stack)
    // Depth = 4. Stores {12-bit PC, 32-bit Mask}
    reg [43:0] simt_stack [0:MAX_WARPS-1][0:3];
    reg [2:0] simt_sp [0:MAX_WARPS-1];

    // Find the first FREE warp slot
    reg [3:0] free_warp_idx;
    reg has_free_warp;
    integer i;

    always @(*) begin
        has_free_warp = 1'b0;
        free_warp_idx = 4'd0;
        alloc.available_slots = 5'd0;
        for (i = MAX_WARPS-1; i >= 0; i = i - 1) begin
            if (warp_state[i] == STATE_FREE || warp_state[i] == STATE_DONE) begin
                has_free_warp = 1'b1;
                free_warp_idx = i; // Will find the lowest index because loop counts down
                alloc.available_slots = alloc.available_slots + 1;
            end
        end
    end

    assign alloc.ready = has_free_warp;

    // Round-Robin Scheduler State
    reg [3:0] rr_idx;

    // Main Context Update & Scheduler Block
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_idx <= 4'd0;
            issue.valid <= 1'b0;
            issue.warp_id <= 4'd0;
            issue.pc <= 12'd0;
            issue.active_mask <= 32'd0;
            issue.block_idx_x <= 16'd0;
            issue.block_idx_y <= 16'd0;
            issue.thread_id_start <= 16'd0;
            
            for (integer j = 0; j < MAX_WARPS; j = j + 1) begin
                warp_state[j] <= STATE_FREE;
                simt_sp[j] <= 3'd0;
            end
        end else begin
            // 1. Handle Warp Allocation
            if (alloc.valid && has_free_warp) begin
                warp_state[free_warp_idx] <= STATE_READY;
                warp_pc[free_warp_idx] <= 12'd0; // Reset PC to 0
                warp_mask[free_warp_idx] <= alloc.active_mask;
                warp_block_id[free_warp_idx] <= alloc.block_id;
                warp_block_idx_x[free_warp_idx] <= alloc.block_idx_x;
                warp_block_idx_y[free_warp_idx] <= alloc.block_idx_y;
                warp_thread_id_start[free_warp_idx] <= alloc.thread_id_start;
            end

            // 2. Handle Feedback (Instruction Complete / Exit)
            // Note: If alloc and wb target the same warp, this simple logic favors wb.
            // But a new allocation will target a FREE warp, while wb targets an active warp, 
            // so they won't collide.
            if (ctx_wb.valid) begin
                if (ctx_wb.is_done) begin
                    warp_state[ctx_wb.warp_id] <= STATE_DONE;
                end else if (ctx_wb.is_divergent) begin
                    // Divergence: Push Not_Taken path to Stack
                    if (simt_sp[ctx_wb.warp_id] < 3'd4) begin
                        simt_stack[ctx_wb.warp_id][simt_sp[ctx_wb.warp_id]] <= {warp_pc[ctx_wb.warp_id] + 12'd1, ctx_wb.not_taken_mask};
                        simt_sp[ctx_wb.warp_id] <= simt_sp[ctx_wb.warp_id] + 3'd1;
                    end
                    // Continue with Taken path
                    warp_pc[ctx_wb.warp_id] <= ctx_wb.next_pc;
                    warp_mask[ctx_wb.warp_id] <= ctx_wb.taken_mask;
                    warp_state[ctx_wb.warp_id] <= STATE_READY;
                end else if (ctx_wb.is_sync) begin
                    // Pop from Stack
                    if (simt_sp[ctx_wb.warp_id] > 3'd0) begin
                        // There is a path on the stack, pop it
                        warp_pc[ctx_wb.warp_id] <= simt_stack[ctx_wb.warp_id][simt_sp[ctx_wb.warp_id] - 1][43:32];
                        warp_mask[ctx_wb.warp_id] <= simt_stack[ctx_wb.warp_id][simt_sp[ctx_wb.warp_id] - 1][31:0];
                        simt_sp[ctx_wb.warp_id] <= simt_sp[ctx_wb.warp_id] - 3'd1;
                        warp_state[ctx_wb.warp_id] <= STATE_READY;
                    end else begin
                        // Fully reconverged or empty stack, just advance PC
                        warp_pc[ctx_wb.warp_id] <= ctx_wb.next_pc;
                        warp_state[ctx_wb.warp_id] <= STATE_READY;
                    end
                end else begin
                    // Normal completion
                    warp_pc[ctx_wb.warp_id] <= ctx_wb.next_pc;
                    warp_state[ctx_wb.warp_id] <= STATE_READY;
                end
            end

            // 3. Dynamic Scheduler (Round-Robin)
            // Look for a READY warp starting from rr_idx
            // Simplified combinational scan for 16 warps
            begin : rr_scheduler
                reg [3:0] next_idx;
                reg found;
                found = 1'b0;
                next_idx = rr_idx;
                
                for (integer k = 0; k < MAX_WARPS; k = k + 1) begin
                    if (!found && warp_state[(rr_idx + k) % MAX_WARPS] == STATE_READY) begin
                        found = 1'b1;
                        next_idx = (rr_idx + k) % MAX_WARPS;
                    end
                end
    
                if (found) begin
                    // A warp is ready to issue!
                    issue.valid <= 1'b1;
                    issue.warp_id <= next_idx;
                    issue.pc <= warp_pc[next_idx];
                    issue.active_mask <= warp_mask[next_idx];
                    issue.block_idx_x <= warp_block_idx_x[next_idx];
                    issue.block_idx_y <= warp_block_idx_y[next_idx];
                    issue.thread_id_start <= warp_thread_id_start[next_idx];
                    
                    // Set state to STALL so we don't issue it again until it writes back
                    warp_state[next_idx] <= STATE_STALL;
                    
                    // Move Round-Robin index to next warp
                    rr_idx <= (next_idx + 1) % MAX_WARPS;
                end else begin
                    issue.valid <= 1'b0;
                end
            end
        end
    end

endmodule
