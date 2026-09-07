`timescale 1ns / 1ps

// Dynamic Thread Block Scheduler (TBS) / GigaThread Engine
// Dispatches Thread Blocks to SMs based on runtime resource availability.

import gpu_pkg::*;

module thread_block_scheduler (
    input wire clk,
    input wire rst_n,

    // Grid Dispatch Interface (From Command Processor)
    input wire start,
    input wire [15:0] grid_dim_x,
    input wire [15:0] grid_dim_y,
    input wire [15:0] block_dim_x,
    input wire [15:0] block_dim_y,
    output reg grid_done,

    // SM Status Interface (From SMs)
    // Flattened array of available warp slots per SM [NUM_SMS-1:0][4:0]
    input wire [(NUM_SMS*5)-1:0] sm_available_warp_slots,
    input wire [NUM_SMS-1:0] sm_block_accepted,

    // SM Dispatch Interface (To SMs)
    output reg [NUM_SMS-1:0] sm_block_issue_valid,
    output reg [15:0] sm_block_idx_x,
    output reg [15:0] sm_block_idx_y,
    output reg [9:0] sm_warps_per_block,
    output wire busy
);

    assign busy = (state != STATE_IDLE);

    // Unpack available warp slots for easier access
    wire [4:0] sm_slots [0:NUM_SMS-1];
    genvar i;
    generate
        for (i = 0; i < NUM_SMS; i = i + 1) begin : unpack_slots
            assign sm_slots[i] = sm_available_warp_slots[(i*5) +: 5];
        end
    endgenerate

    // State Machine
    localparam STATE_IDLE = 2'd0;
    localparam STATE_ISSUE = 2'd1;
    localparam STATE_WAIT_ACK = 2'd2;
    localparam STATE_WAIT_DONE = 2'd3;

    reg [1:0] state;
    reg [15:0] current_block_x;
    reg [15:0] current_block_y;
    reg [31:0] threads_per_block;
    reg [4:0] warps_per_block;
    reg [3:0] chosen_sm_idx;

    // Arbitration / Selection Logic (Combinational)
    reg [4:0] max_slots;
    reg [3:0] best_sm;
    reg sm_found;
    integer j;

    always @(*) begin
        max_slots = 0;
        best_sm = 0;
        sm_found = 1'b0;
        
        for (j = 0; j < NUM_SMS; j = j + 1) begin
            if (sm_slots[j] >= warps_per_block && sm_slots[j] > max_slots) begin
                max_slots = sm_slots[j];
                best_sm = j;
                sm_found = 1'b1;
            end
        end
    end

    // Check if all SMs are fully idle
    reg all_idle;
    always @(*) begin
        all_idle = 1'b1;
        for (j = 0; j < NUM_SMS; j = j + 1) begin
            if (sm_slots[j] != MAX_WARPS[4:0]) begin
                all_idle = 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            grid_done <= 1'b0;
            sm_block_issue_valid <= {NUM_SMS{1'b0}};
            chosen_sm_idx <= 0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    grid_done <= 1'b0;
                    if (start) begin
                        current_block_x <= 0;
                        current_block_y <= 0;
                        // Calculate warps per block: ceil(threads / 32)
                        threads_per_block = block_dim_x * block_dim_y;
                        warps_per_block <= (threads_per_block + 31) >> 5;
                        state <= STATE_ISSUE;
                    end
                end

                STATE_ISSUE: begin
                    if (sm_found) begin
                        // Dispatch to the best SM
                        sm_block_issue_valid[best_sm] <= 1'b1;
                        sm_block_idx_x <= current_block_x;
                        sm_block_idx_y <= current_block_y;
                        sm_warps_per_block <= warps_per_block;
                        chosen_sm_idx <= best_sm;
                        state <= STATE_WAIT_ACK;
                    end
                end

                STATE_WAIT_ACK: begin
                    // Wait for the chosen SM to accept the block
                    if (sm_block_accepted[chosen_sm_idx]) begin
                        sm_block_issue_valid[chosen_sm_idx] <= 1'b0;
                        
                        // Increment block coordinates
                        if (current_block_x == grid_dim_x - 1) begin
                            current_block_x <= 0;
                            if (current_block_y == grid_dim_y - 1) begin
                                // All blocks issued
                                state <= STATE_WAIT_DONE;
                            end else begin
                                current_block_y <= current_block_y + 1;
                                state <= STATE_ISSUE;
                            end
                        end else begin
                            current_block_x <= current_block_x + 1;
                            state <= STATE_ISSUE;
                        end
                    end
                end

                STATE_WAIT_DONE: begin
                    // Wait for all SMs to finish processing
                    if (all_idle) begin
                        grid_done <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
