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

    // request signal to SM wise L1 Cache
    output wire lsu_ready,
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
    , output wire [31:0] debug_lsu,
      output wire [31:0] debug_lsu_addr
`endif
);
    localparam OP_LDR = 8'hA0;
    localparam OP_STR = 8'hA1;
    localparam ST_IDLE = 2'd0;
    localparam ST_ISSUE = 2'd1;
    localparam ST_WAIT = 2'd2;
    localparam FIFO_DEPTH = MAX_WARPS;
    localparam FIFO_PTR_W = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;

    reg [1:0] state;
    reg active_is_load;
    reg active_is_uniform;
    reg active_lane1_pending;
    reg active_word_sel;
    reg active_lane1_word_sel;
    reg [$clog2(MAX_WARPS)-1:0] active_warp_id;
    reg [11:0] active_pc;
    reg [4:0] active_rd;
    reg [31:0] lane1_addr;
    reg [31:0] lane1_wdata;
    reg [31:0] lane0_rdata;

    reg [$clog2(MAX_WARPS)-1:0] fifo_warp_id [0:FIFO_DEPTH-1];
    reg [11:0] fifo_pc [0:FIFO_DEPTH-1];
    reg [4:0] fifo_rd [0:FIFO_DEPTH-1];
    reg fifo_is_load [0:FIFO_DEPTH-1];
    reg [31:0] fifo_addr [0:FIFO_DEPTH-1];
    reg [31:0] fifo_lane1_addr [0:FIFO_DEPTH-1];
    reg [DATA_W-1:0] fifo_wdata [0:FIFO_DEPTH-1];
    reg fifo_is_uniform [0:FIFO_DEPTH-1];
    reg fifo_word_sel [0:FIFO_DEPTH-1];
    reg fifo_lane1_word_sel [0:FIFO_DEPTH-1];
    reg [FIFO_PTR_W-1:0] fifo_wr_ptr;
    reg [FIFO_PTR_W-1:0] fifo_rd_ptr;
    reg [$clog2(FIFO_DEPTH+1)-1:0] fifo_count;

    wire op_is_mem = op.valid && (op.opcode == OP_LDR || op.opcode == OP_STR);
    wire request_fire = l1_req_valid && l1_req_ready;
    wire response_fire = l1_rsp_valid;
    wire word_sel = op.rs1_data[2];
    wire is_uniform = (op.rs1_data[31:0] == op.rs1_data[63:32]);

    wire fifo_push = op_is_mem && (fifo_count < FIFO_DEPTH);
    wire fifo_pop = (state == ST_IDLE) && (fifo_count != 0);
    assign lsu_ready = (fifo_count < FIFO_DEPTH);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            active_is_load <= 1'b0;
            active_is_uniform <= 1'b0;
            active_lane1_pending <= 1'b0;
            active_word_sel <= 1'b0;
            active_lane1_word_sel <= 1'b0;
            active_warp_id <= '0;
            active_pc <= '0;
            active_rd <= '0;
            lane1_addr <= '0;
            lane1_wdata <= '0;
            lane0_rdata <= '0;
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
            fifo_count <= '0;
            l1_req_valid <= 1'b0;
            l1_req_addr <= '0;
            l1_req_wdata <= '0;
            l1_req_we <= 1'b0;
            l1_req_wstrb <= '0;
            wb.valid <= 1'b0;
            wb.warp_id <= '0;
            wb.rd <= '0;
            wb.data <= '0;
            wb.mask <= '0;
            ctx_wb.valid <= 1'b0;
            ctx_wb.warp_id <= '0;
            ctx_wb.next_pc <= '0;
        end else begin
            wb.valid <= 1'b0;
            ctx_wb.valid <= 1'b0;

            if (fifo_push) begin
                fifo_warp_id[fifo_wr_ptr] <= op.warp_id;
                fifo_pc[fifo_wr_ptr] <= op.pc;
                fifo_rd[fifo_wr_ptr] <= op.rd;
                fifo_is_load[fifo_wr_ptr] <= (op.opcode == OP_LDR);
                fifo_addr[fifo_wr_ptr] <= op.rs1_data[31:0];
                fifo_lane1_addr[fifo_wr_ptr] <= op.rs1_data[63:32];
                fifo_wdata[fifo_wr_ptr] <= op.rs2_data;
                fifo_is_uniform[fifo_wr_ptr] <= is_uniform;
                fifo_word_sel[fifo_wr_ptr] <= word_sel;
                fifo_lane1_word_sel[fifo_wr_ptr] <= op.rs1_data[34];
                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
            end

            if (fifo_pop)
                fifo_rd_ptr <= fifo_rd_ptr + 1'b1;

            case ({fifo_push, fifo_pop})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase

            case (state)
                ST_IDLE: begin
                    if (fifo_pop) begin
                        active_is_load <= fifo_is_load[fifo_rd_ptr];
                        active_is_uniform <= fifo_is_uniform[fifo_rd_ptr];
                        active_lane1_pending <= !fifo_is_uniform[fifo_rd_ptr];
                        active_word_sel <= fifo_word_sel[fifo_rd_ptr];
                        active_lane1_word_sel <= fifo_lane1_word_sel[fifo_rd_ptr];
                        active_warp_id <= fifo_warp_id[fifo_rd_ptr];
                        active_pc <= fifo_pc[fifo_rd_ptr];
                        active_rd <= fifo_rd[fifo_rd_ptr];
                        lane1_addr <= fifo_lane1_addr[fifo_rd_ptr];
                        lane1_wdata <= fifo_wdata[fifo_rd_ptr][63:32];

                        l1_req_valid <= 1'b1;
                        l1_req_addr <= fifo_addr[fifo_rd_ptr];
                        l1_req_wdata <= {fifo_wdata[fifo_rd_ptr][31:0], fifo_wdata[fifo_rd_ptr][31:0]};
                        l1_req_we <= !fifo_is_load[fifo_rd_ptr];
                        l1_req_wstrb <= fifo_word_sel[fifo_rd_ptr] ? 8'hF0 : 8'h0F;
                        state <= ST_ISSUE;
                    end
                end

                ST_ISSUE: begin
                    if (request_fire) begin
                        l1_req_valid <= 1'b0;
                        state <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (response_fire) begin
                        if (active_lane1_pending) begin
                            if (active_is_load && active_rd != 5'd0)
                                lane0_rdata <= active_word_sel ? l1_rsp_rdata[63:32] : l1_rsp_rdata[31:0];

                            l1_req_valid <= 1'b1;
                            l1_req_addr <= lane1_addr;
                            l1_req_wdata <= {lane1_wdata, lane1_wdata};
                            l1_req_we <= !active_is_load;
                            l1_req_wstrb <= active_lane1_word_sel ? 8'hF0 : 8'h0F;
                            active_word_sel <= active_lane1_word_sel;
                            active_lane1_pending <= 1'b0;
                            state <= ST_ISSUE;
                        end else begin
                            if (active_is_load && active_rd != 5'd0) begin
                                wb.valid <= 1'b1;
                                wb.warp_id <= active_warp_id;
                                wb.rd <= active_rd;
                                wb.mask <= 32'hFFFFFFFF;
                                if (active_is_uniform)
                                    wb.data <= active_word_sel ? {l1_rsp_rdata[63:32], l1_rsp_rdata[63:32]} :
                                                               {l1_rsp_rdata[31:0], l1_rsp_rdata[31:0]};
                                else
                                    wb.data <= {active_word_sel ? l1_rsp_rdata[63:32] : l1_rsp_rdata[31:0], lane0_rdata};
                            end

                            ctx_wb.valid <= 1'b1;
                            ctx_wb.warp_id <= active_warp_id;
                            ctx_wb.next_pc <= active_pc + 12'd1;
                            state <= ST_IDLE;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

`ifdef ENABLE_GPU_DEBUG
    assign debug_lsu_addr = l1_req_addr;
    assign debug_lsu = {
        25'd0,
        l1_rsp_valid,
        l1_req_ready,
        l1_req_valid,
        lsu_ready,
        active_is_load,
        state
    };
`endif
endmodule
