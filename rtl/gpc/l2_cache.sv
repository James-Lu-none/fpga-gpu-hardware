`timescale 1ns / 1ps
// GPC L2 Shared Cache & AXI4 Master
// Services L1 misses from NUM_PORTS SMs and interfaces with DDR3 via AXI4.
// Capacity: 16KB (512 lines x 32 Bytes) Direct Mapped, Write-Through

import gpu_pkg::*;

module l2_cache #(
    parameter NUM_PORTS = gpu_pkg::NUM_SMS
)(
    input wire clk,
    input wire rst_n,
    input wire flush,
    input wire [NUM_PORTS-1:0] sm_req_valid,
    input wire [31:0] sm_req_addr [0:NUM_PORTS-1],
    input wire [255:0] sm_req_wdata [0:NUM_PORTS-1],
    input wire [31:0] sm_req_wstrb [0:NUM_PORTS-1],
    input wire [NUM_PORTS-1:0] sm_req_we,
    output wire [NUM_PORTS-1:0] sm_req_ready,
    output reg [NUM_PORTS-1:0] sm_rsp_valid,
    output reg [255:0] sm_rsp_rdata [0:NUM_PORTS-1],
    output wire m_axi_awvalid,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    input wire m_axi_awready,
    output wire m_axi_wvalid,
    output wire [255:0] m_axi_wdata,
    output wire [31:0] m_axi_wstrb,
    output wire m_axi_wlast,
    input wire m_axi_wready,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire m_axi_arvalid,
    output wire [31:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    input wire m_axi_arready,
    input wire m_axi_rvalid,
    input wire [255:0] m_axi_rdata,
    input wire m_axi_rlast,
    output wire m_axi_rready
`ifdef ENABLE_GPU_DEBUG
    , output wire [15:0] debug_l2
`endif
);
    localparam PORT_SEL_W = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1;
    reg [PORT_SEL_W-1:0] current_sm;
    wire selected_valid = sm_req_valid[current_sm];
    wire selected_rsp_valid;
    wire [255:0] selected_rsp_data;

    cache_line_if #(.ADDR_W(32), .DATA_W(256)) core_bus();
    cache_line_if #(.ADDR_W(32), .DATA_W(256)) memory_bus();
    reg aw_done;
    reg w_done;

    assign core_bus.req_valid = selected_valid;
    assign core_bus.req_addr = sm_req_addr[current_sm];
    assign core_bus.req_wdata = sm_req_wdata[current_sm];
    assign core_bus.req_wstrb = sm_req_wstrb[current_sm];
    assign core_bus.req_we = sm_req_we[current_sm];

    for (genvar p = 0; p < NUM_PORTS; p = p + 1) begin : gen_ready
        assign sm_req_ready[p] = (current_sm == p) && core_bus.req_ready;
    end

    assign selected_rsp_valid = core_bus.rsp_valid;
    assign selected_rsp_data = core_bus.rsp_rdata;

    assign memory_bus.req_ready = memory_bus.req_we ?
                                  (aw_done && w_done) : m_axi_arready;
    assign memory_bus.rsp_valid = memory_bus.req_we ? m_axi_bvalid :
                                  (m_axi_rvalid && m_axi_rlast);
    assign memory_bus.rsp_rdata = m_axi_rdata;

    assign m_axi_awvalid = memory_bus.req_valid && memory_bus.req_we && !aw_done;
    assign m_axi_awaddr = memory_bus.req_addr;
    assign m_axi_awlen = 8'd0;
    assign m_axi_awsize = 3'b101;
    assign m_axi_awburst = 2'b01;
    assign m_axi_wvalid = memory_bus.req_valid && memory_bus.req_we && !w_done;
    assign m_axi_wdata = memory_bus.req_wdata;
    assign m_axi_wstrb = memory_bus.req_wstrb;
    assign m_axi_wlast = 1'b1;
    assign m_axi_bready = memory_bus.rsp_ready && memory_bus.req_we;

    assign m_axi_arvalid = memory_bus.req_valid && !memory_bus.req_we;
    assign m_axi_araddr = memory_bus.req_addr;
    assign m_axi_arlen = 8'd0;
    assign m_axi_arsize = 3'b101;
    assign m_axi_arburst = 2'b01;
    assign m_axi_rready = memory_bus.rsp_ready && !memory_bus.req_we;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            aw_done <= 1'b0;
            w_done <= 1'b0;
        end else begin
            if (!memory_bus.req_valid || !memory_bus.req_we) begin
                aw_done <= 1'b0;
                w_done <= 1'b0;
            end else begin
                if (m_axi_awvalid && m_axi_awready)
                    aw_done <= 1'b1;
                if (m_axi_wvalid && m_axi_wready)
                    w_done <= 1'b1;
            end
        end
    end

    unified_cache #(
        .NUM_LINES (512),
        .INDEX_BITS (9),
        .TAG_BITS (18)
    ) u_cache (
        .clk (clk),
        .rst_n (rst_n),
        .flush (flush),
        .core (core_bus),
        .memory (memory_bus)
    );

    function [PORT_SEL_W-1:0] next_port(input [PORT_SEL_W-1:0] port);
        if (NUM_PORTS <= 1)
            next_port = '0;
        else if (port == PORT_SEL_W'(NUM_PORTS - 1))
            next_port = '0;
        else
            next_port = port + 1'b1;
    endfunction

    integer p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_sm <= '0;
            sm_rsp_valid <= '0;
            for (p = 0; p < NUM_PORTS; p = p + 1)
                sm_rsp_rdata[p] <= '0;
        end else begin
            sm_rsp_valid <= '0;
            if (selected_rsp_valid) begin
                sm_rsp_valid[current_sm] <= 1'b1;
                sm_rsp_rdata[current_sm] <= selected_rsp_data;
                current_sm <= next_port(current_sm);
            end else if (!selected_valid && core_bus.req_ready && NUM_PORTS > 1) begin
                // Once a request is accepted, unified_cache deasserts
                // core_bus.req_ready while it performs lookup/AXI work.
                // Keep current_sm fixed during that interval; rotating here
                // would route the eventual response to a different SM.
                current_sm <= next_port(current_sm);
            end
        end
    end

`ifdef ENABLE_GPU_DEBUG
    assign debug_l2 = {
        m_axi_rready, m_axi_rvalid,
        m_axi_arready, m_axi_arvalid,
        m_axi_bready, m_axi_bvalid,
        m_axi_wready, m_axi_wvalid,
        m_axi_awready, m_axi_awvalid,
        core_bus.req_ready, selected_valid,
        1'b0, 3'd0
    };
`endif
endmodule
