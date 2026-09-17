`timescale 1ns / 1ps
// LSU (Load/Store Unit)
//
// LSU handles all memory access instructions (LDR, STR). It is 
// "Decoupled" from the main ALU pipeline. This means when a warp executes 
// a memory instruction, it is offloaded to the LSU, and the main scheduler 
// can immediately issue instructions from OTHER warps, hiding memory latency.
//

import gpu_pkg::*;

module lsu (
    input wire clk,
    input wire rst_n,

    // Operand Interface (From Dispatcher / VRF)
    operand_if.slave op,
    output wire lsu_ready, // LSU can accept new instruction

    // request signal to SM wise L1 Cache
    output reg l1_req_valid,
    output reg [31:0] l1_req_addr,
    output reg [DATA_W-1:0] l1_req_wdata,
    output reg l1_req_we,
    output reg [7:0] l1_req_wstrb,
    input wire l1_req_ready,

    input wire l1_rsp_valid,
    input wire [DATA_W-1:0] l1_rsp_rdata,

    // Write-Back Interface to VRF
    // with target warp_id, target register number (rd)
    wb_if.master wb,

    // Write-Back Interface to Context Scheduler
    ctx_wb_if.master ctx_wb
`ifdef ENABLE_GPU_DEBUG
    ,
    // Debug Status Outputs
    output wire [31:0] debug_lsu,
    output wire [31:0] debug_lsu_addr
`endif
);

    localparam OP_LDR = 8'hA0;
    localparam OP_STR = 8'hA1;

    // We keep it simple: 1 active request at a time for this simple LSU
    // In a real GPU, M LSUs can track M outstanding requests using a scoreboard/MSHR.
    localparam STATE_IDLE = 1'b0;
    localparam STATE_WAIT = 1'b1;

    reg state;
    reg [$clog2(MAX_WARPS)-1:0] active_warp_id;
    reg [11:0] active_pc;
    reg [4:0] active_rd;
    reg is_load;
    reg active_is_uniform;
    reg active_word_sel;
    reg active_lane1_pending;
    reg [31:0] active_rs1_lane1;
    reg [31:0] active_rs2_lane1;

    // Multi-Warp Request FIFO (Depth = MAX_WARPS)
    // Prevents memory requests from concurrent warps from being dropped while LSU is waiting on L1/DDR3.
    reg [$clog2(MAX_WARPS)-1:0] fifo_warp_id [0:MAX_WARPS-1];
    reg [11:0]                  fifo_pc      [0:MAX_WARPS-1];
    reg [4:0]                   fifo_rd      [0:MAX_WARPS-1];
    reg                         fifo_is_load [0:MAX_WARPS-1];
    reg [31:0]                  fifo_addr    [0:MAX_WARPS-1];
    reg [31:0]                  fifo_rs1_lane1 [0:MAX_WARPS-1];
    reg [DATA_W-1:0]            fifo_wdata   [0:MAX_WARPS-1];
    reg                         fifo_we      [0:MAX_WARPS-1];
    reg                         fifo_is_uniform [0:MAX_WARPS-1];
    reg                         fifo_word_sel   [0:MAX_WARPS-1];

    reg [$clog2(MAX_WARPS)-1:0] fifo_wr_ptr;
    reg [$clog2(MAX_WARPS)-1:0] fifo_rd_ptr;
    reg [$clog2(MAX_WARPS):0]   fifo_count;

    wire op_is_mem = op.valid && (op.opcode == OP_LDR || op.opcode == OP_STR);
    wire is_uniform_req = (op.rs1_data[31:0] == op.rs1_data[63:32]);
    wire word_sel_req   = op.rs1_data[2];
    assign lsu_ready = (fifo_count < MAX_WARPS);

    wire fifo_push = op_is_mem && (fifo_count < MAX_WARPS) &&
                     ((state == STATE_WAIT) || (state == STATE_IDLE && fifo_count > 0));

    wire fifo_pop = (state == STATE_IDLE && fifo_count > 0) ||
                    (state == STATE_WAIT && l1_rsp_valid && !active_lane1_pending && fifo_count > 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= STATE_IDLE;
            is_load         <= 1'b0;
            active_warp_id  <= '0;
            active_pc       <= 12'd0;
            active_rd       <= 5'd0;
            active_is_uniform <= 1'b0;
            active_word_sel   <= 1'b0;
            l1_req_valid    <= 1'b0;
            l1_req_addr     <= 32'd0;
            l1_req_wdata    <= '0;
            l1_req_we       <= 1'b0;
            
            wb.valid        <= 1'b0;
            wb.warp_id      <= '0;
            wb.rd           <= 5'd0;
            wb.data         <= '0;
            wb.mask         <= 32'd0;
            ctx_wb.valid    <= 1'b0;
            ctx_wb.warp_id  <= '0;
            ctx_wb.next_pc  <= 12'd0;
            
            fifo_wr_ptr     <= '0;
            fifo_rd_ptr     <= '0;
            fifo_count      <= '0;
        end else begin
            // Default 1-cycle pulses deassert
            wb.valid     <= 1'b0;
            ctx_wb.valid <= 1'b0;

            // Handshake with L1 Cache Request Channel
            if (l1_req_valid && l1_req_ready) begin
                l1_req_valid <= 1'b0;
            end

            // 1. FIFO Enqueue Logic
            if (fifo_push) begin
                fifo_warp_id[fifo_wr_ptr]    <= op.warp_id;
                fifo_pc[fifo_wr_ptr]         <= op.pc;
                fifo_rd[fifo_wr_ptr]         <= op.rd;
                fifo_is_load[fifo_wr_ptr]    <= (op.opcode == OP_LDR);
                fifo_addr[fifo_wr_ptr]       <= op.rs1_data[31:0];
                fifo_rs1_lane1[fifo_wr_ptr]  <= op.rs1_data[63:32];
                fifo_wdata[fifo_wr_ptr]      <= op.rs2_data;
                fifo_we[fifo_wr_ptr]         <= (op.opcode == OP_STR);
                fifo_is_uniform[fifo_wr_ptr] <= is_uniform_req;
                fifo_word_sel[fifo_wr_ptr]   <= word_sel_req;
                fifo_wr_ptr                  <= fifo_wr_ptr + 1'b1;
            end

            // 2. FIFO Count Tracking
            if (fifo_push && !fifo_pop) begin
                fifo_count <= fifo_count + 1'b1;
            end else if (!fifo_push && fifo_pop) begin
                fifo_count <= fifo_count - 1'b1;
            end

            // 3. FIFO Dequeue Logic
            if (fifo_pop) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
            end

            // 4. State Machine & Execution Logic
            case (state)
                STATE_IDLE: begin
                    if (fifo_pop) begin
                        // Launch popped request from FIFO
                        l1_req_valid      <= 1'b1;
                        l1_req_addr       <= fifo_addr[fifo_rd_ptr];
                        l1_req_wdata      <= {fifo_wdata[fifo_rd_ptr][31:0], fifo_wdata[fifo_rd_ptr][31:0]}; // Duplicated for word align
                        l1_req_wstrb      <= fifo_word_sel[fifo_rd_ptr] ? 8'hF0 : 8'h0F;
                        l1_req_we         <= fifo_we[fifo_rd_ptr];
                        active_warp_id    <= fifo_warp_id[fifo_rd_ptr];
                        active_pc         <= fifo_pc[fifo_rd_ptr];
                        active_rd         <= fifo_rd[fifo_rd_ptr];
                        is_load           <= fifo_is_load[fifo_rd_ptr];
                        active_is_uniform <= fifo_is_uniform[fifo_rd_ptr];
                        active_word_sel   <= fifo_word_sel[fifo_rd_ptr];
                        active_lane1_pending <= !fifo_is_uniform[fifo_rd_ptr];
                        active_rs1_lane1  <= fifo_rs1_lane1[fifo_rd_ptr];
                        active_rs2_lane1  <= fifo_wdata[fifo_rd_ptr][63:32]; // Note: fifo_wdata holds rs2_data for stores
                        state             <= STATE_WAIT;
                    end else if (op_is_mem && fifo_count == 0) begin
                        // Direct bypass: FIFO is empty and LSU is idle
                        l1_req_valid      <= 1'b1;
                        l1_req_addr       <= op.rs1_data[31:0];
                        l1_req_wdata      <= {op.rs2_data[31:0], op.rs2_data[31:0]}; // Duplicated for word align
                        l1_req_wstrb      <= word_sel_req ? 8'hF0 : 8'h0F;
                        l1_req_we         <= (op.opcode == OP_STR);
                        active_warp_id    <= op.warp_id;
                        active_pc         <= op.pc;
                        active_rd         <= op.rd;
                        is_load           <= (op.opcode == OP_LDR);
                        active_is_uniform <= is_uniform_req;
                        active_word_sel   <= word_sel_req;
                        active_lane1_pending <= !is_uniform_req;
                        active_rs1_lane1  <= op.rs1_data[63:32];
                        active_rs2_lane1  <= op.rs2_data[63:32];
                        state             <= STATE_WAIT;
                    end
                end

                STATE_WAIT: begin
                    if (l1_rsp_valid) begin
                        // Complete active request
                        if (is_load && (active_rd != 5'd0)) begin
                            wb.valid   <= 1'b1;
                            wb.warp_id <= active_warp_id;
                            wb.rd      <= active_rd;
                            wb.mask    <= 32'hFFFFFFFF;
                            if (active_is_uniform) begin
                                // Uniform Scalar Broadcast across SIMD lanes
                                wb.data <= active_word_sel ? {l1_rsp_rdata[63:32], l1_rsp_rdata[63:32]}
                                                           : {l1_rsp_rdata[31:0],  l1_rsp_rdata[31:0]};
                            end else begin
                                // Contiguous Vector Load
                                wb.data <= l1_rsp_rdata;
                            end
                        end
                        if (active_lane1_pending) begin
                            // Issue Phase 1 for Divergent Access
                            l1_req_valid      <= 1'b1;
                            l1_req_addr       <= active_rs1_lane1;
                            l1_req_wdata      <= {active_rs2_lane1, active_rs2_lane1};
                            l1_req_wstrb      <= active_rs1_lane1[2] ? 8'hF0 : 8'h0F;
                            l1_req_we         <= !is_load; // Same operation type
                            active_lane1_pending <= 1'b0;
                            // Update active_word_sel for the upcoming Phase 1 response
                            active_word_sel   <= active_rs1_lane1[2];
                            state             <= STATE_WAIT;
                        end else begin
                            ctx_wb.valid   <= 1'b1;
                            ctx_wb.warp_id <= active_warp_id;
                            ctx_wb.next_pc <= active_pc + 12'd1;

                            if (fifo_pop) begin
                                // Immediately launch next request from FIFO
                                l1_req_valid      <= 1'b1;
                                l1_req_addr       <= fifo_addr[fifo_rd_ptr];
                                l1_req_wdata      <= {fifo_wdata[fifo_rd_ptr][31:0], fifo_wdata[fifo_rd_ptr][31:0]};
                                l1_req_wstrb      <= fifo_word_sel[fifo_rd_ptr] ? 8'hF0 : 8'h0F;
                                l1_req_we         <= fifo_we[fifo_rd_ptr];
                                active_warp_id    <= fifo_warp_id[fifo_rd_ptr];
                                active_pc         <= fifo_pc[fifo_rd_ptr];
                                active_rd         <= fifo_rd[fifo_rd_ptr];
                                is_load           <= fifo_is_load[fifo_rd_ptr];
                                active_is_uniform <= fifo_is_uniform[fifo_rd_ptr];
                                active_word_sel   <= fifo_word_sel[fifo_rd_ptr];
                                active_lane1_pending <= !fifo_is_uniform[fifo_rd_ptr];
                                active_rs1_lane1  <= fifo_rs1_lane1[fifo_rd_ptr];
                                active_rs2_lane1  <= fifo_wdata[fifo_rd_ptr][63:32];
                                state             <= STATE_WAIT;
                            end else begin
                                state             <= STATE_IDLE;
                            end
                        end
                    end
                end
            endcase
        end
    end

`ifdef ENABLE_GPU_DEBUG
    // Debug Status Multiplexing
    assign debug_lsu_addr = l1_req_addr;
    assign debug_lsu = {
        6'd0,
        fifo_count[3:0],    // [25:22]: Pending FIFO queue depth
        active_pc[11:0],    // [21:10]
        4'(active_warp_id), // [9:6]
        l1_rsp_valid,       // [5]
        l1_req_ready,       // [4]
        l1_req_valid,       // [3]
        lsu_ready,          // [2]
        is_load,            // [1]
        state               // [0]
    };
`endif

endmodule
