`timescale 1ns / 1ps

interface cache_line_if #(
    parameter ADDR_W = 32,
    parameter DATA_W = 256
);
    localparam STRB_W = DATA_W / 8;

    logic req_valid;
    logic [ADDR_W-1:0] req_addr;
    logic [DATA_W-1:0] req_wdata;
    logic [STRB_W-1:0] req_wstrb;
    logic req_we;
    logic req_ready;

    logic rsp_valid;
    logic [DATA_W-1:0] rsp_rdata;
    logic rsp_ready;

    modport client (
        output req_valid, req_addr, req_wdata, req_wstrb, req_we,
        input req_ready, rsp_valid, rsp_rdata,
        output rsp_ready
    );

    modport cache (
        input req_valid, req_addr, req_wdata, req_wstrb, req_we,
        output req_ready, rsp_valid, rsp_rdata,
        input rsp_ready
    );
endinterface