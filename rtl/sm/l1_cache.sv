`timescale 1ns / 1ps

import gpu_pkg::*;

module l1_cache (
    input wire clk,
    input wire rst_n,
    input wire flush,
    input wire req_valid,
    input wire [31:0] req_addr,
    input wire [DATA_W-1:0] req_wdata,
    input wire req_we,
    input wire [7:0] req_wstrb,
    output wire req_ready,
    output wire rsp_valid,
    output wire [DATA_W-1:0] rsp_rdata,
    output wire l2_req_valid,
    output wire [31:0] l2_req_addr,
    output wire [255:0] l2_req_wdata,
    output wire [31:0] l2_req_wstrb,
    output wire l2_req_we,
    input wire l2_req_ready,
    input wire l2_rsp_valid,
    input wire [255:0] l2_rsp_rdata
`ifdef ENABLE_GPU_DEBUG
    , output wire [15:0] debug_l1
`endif
);
    cache_line_if #(.ADDR_W(32), .DATA_W(256)) core_bus();
    cache_line_if #(.ADDR_W(32), .DATA_W(256)) l2_bus();
    wire [4:0] req_offset = req_addr[4:0];
    wire [1:0] req_qword = req_offset[4:3];
    reg [1:0] rsp_qword_q;
    reg l2_rsp_pending;
    reg [255:0] l2_rsp_data_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_qword_q <= 2'd0;
            l2_rsp_pending <= 1'b0;
            l2_rsp_data_q <= '0;
        end else begin
            if (core_bus.req_valid && core_bus.req_ready)
                rsp_qword_q <= req_qword;

            // L2 currently exposes a pulse response. Hold it until the
            // unified cache consumes it, so AXI completion cannot be lost at
            // the L1/L2 clock-edge boundary. This is especially important for
            // stores, because losing the response leaves LSU in ST_WAIT.
            if (l2_rsp_valid) begin
                l2_rsp_pending <= 1'b1;
                l2_rsp_data_q <= l2_rsp_rdata;
            end else if (l2_rsp_pending && l2_bus.rsp_ready) begin
                l2_rsp_pending <= 1'b0;
            end
        end
    end

    assign core_bus.req_valid = req_valid;
    assign core_bus.req_addr = req_addr;
    assign core_bus.req_wdata = {192'd0, req_wdata} << (req_qword * 64);
    assign core_bus.req_wstrb = {24'd0, req_wstrb} << (req_qword * 8);
    assign core_bus.req_we = req_we;
    assign req_ready = core_bus.req_ready;
    assign rsp_valid = core_bus.rsp_valid;
    assign rsp_rdata = (rsp_qword_q == 2'd0) ? core_bus.rsp_rdata[63:0] :
                       (rsp_qword_q == 2'd1) ? core_bus.rsp_rdata[127:64] :
                       (rsp_qword_q == 2'd2) ? core_bus.rsp_rdata[191:128] :
                                                   core_bus.rsp_rdata[255:192];

    assign l2_req_valid = l2_bus.req_valid;
    assign l2_req_addr = l2_bus.req_addr;
    assign l2_req_wdata = l2_bus.req_wdata;
    assign l2_req_wstrb = l2_bus.req_wstrb;
    assign l2_req_we = l2_bus.req_we;
    assign l2_bus.req_ready = l2_req_ready;
    assign l2_bus.rsp_valid = l2_rsp_pending;
    assign l2_bus.rsp_rdata = l2_rsp_data_q;

    unified_cache #(
        .NUM_LINES (64),
        .INDEX_BITS (6),
        .TAG_BITS (21)
    ) u_cache (
        .clk (clk),
        .rst_n (rst_n),
        .flush (flush),
        .core (core_bus),
        .memory (l2_bus)
    );

`ifdef ENABLE_GPU_DEBUG
    assign debug_l1 = {
        8'd0,
        l2_bus.rsp_valid,
        l2_bus.req_ready,
        l2_bus.req_valid,
        core_bus.rsp_valid,
        core_bus.req_ready,
        core_bus.req_we,
        2'd0
    };
`endif
endmodule
