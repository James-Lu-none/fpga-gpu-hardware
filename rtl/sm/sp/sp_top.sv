`timescale 1ns / 1ps
// Streaming Multiprocessor (SM) Compute Core - TRUE SIMT ARCHITECTURE
// Top-level module encapsulating the Warp Scheduler, Fetch/Decode, 
// Vector Register File, and Execution Pipeline.

import gpu_pkg::*;

module sub_partition (
    input wire clk,
    input wire rst_n,

    // Instruction Load Interface (From Hardware Engine)
    input wire iram_we,
    input wire [11:0] iram_waddr,
    input wire [31:0] iram_wdata,

    // Warp Launch Interface (From Warp Scheduler)
    warp_alloc_if.slave alloc,

    // L1 Cache Interface (To SM Global L1 Cache)
    output wire l1_req_valid,
    output wire [31:0] l1_req_addr,
    output wire [63:0] l1_req_wdata,
    output wire l1_req_we,
    input wire l1_req_ready,
    input wire l1_rsp_valid,
    input wire [63:0] l1_rsp_rdata
);

    // Reset Pipeline (Level 3)
    (* ASYNC_REG = "TRUE" *) reg core_rst_n_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) core_rst_n_reg <= 1'b0;
        else        core_rst_n_reg <= 1'b1;
    end
    wire core_rst_n = core_rst_n_reg;

    // Inter-module Interconnect Interfaces
    issue_if issue();
    decode_if decode();
    operand_if op();
    
    wb_if alu_wb();
    ctx_wb_if ctx_alu_wb();
    
    wb_if lsu_wb();
    ctx_wb_if ctx_lsu_wb(); // LSU doesn't really generate branch convergence, but we use interface anyway
    
    wb_if wb();
    ctx_wb_if ctx_wb();

    // Write-Back Arbiter (LSU has priority)
    assign wb.valid = lsu_wb.valid ? lsu_wb.valid : alu_wb.valid;
    assign wb.warp_id = lsu_wb.valid ? lsu_wb.warp_id : alu_wb.warp_id;
    assign wb.rd = lsu_wb.valid ? lsu_wb.rd : alu_wb.rd;
    assign wb.data = lsu_wb.valid ? lsu_wb.data : alu_wb.data;
    assign wb.mask = lsu_wb.valid ? lsu_wb.mask : alu_wb.mask;
    
    assign ctx_wb.valid = lsu_wb.valid ? ctx_lsu_wb.valid : ctx_alu_wb.valid;
    assign ctx_wb.warp_id = lsu_wb.valid ? ctx_lsu_wb.warp_id : ctx_alu_wb.warp_id;
    assign ctx_wb.next_pc = lsu_wb.valid ? ctx_lsu_wb.next_pc : ctx_alu_wb.next_pc;
    assign ctx_wb.is_done = lsu_wb.valid ? 1'b0 : ctx_alu_wb.is_done;
    assign ctx_wb.taken_mask = lsu_wb.valid ? 32'd0 : ctx_alu_wb.taken_mask;
    assign ctx_wb.not_taken_mask = lsu_wb.valid ? 32'd0 : ctx_alu_wb.not_taken_mask;
    assign ctx_wb.is_divergent = lsu_wb.valid ? 1'b0 : ctx_alu_wb.is_divergent;
    assign ctx_wb.is_sync = lsu_wb.valid ? 1'b0 : ctx_alu_wb.is_sync;

    // 1. Warp Context & Dynamic Scheduler
    warp_context u_warp_context (
        .clk (clk),
        .rst_n (core_rst_n),
        .alloc (alloc),
        .issue (issue),
        .ctx_wb (ctx_wb)
    );

    // 2. Instruction Fetch & Decode
    fetch_decode u_fetch_decode (
        .clk (clk),
        .rst_n (core_rst_n),
        .iram_we (iram_we),
        .iram_waddr (iram_waddr),
        .iram_wdata (iram_wdata),
        .issue (issue),
        .decode (decode)
    );

    // 3. Vector Register File (VRF)
    vector_regfile u_vector_regfile (
        .clk (clk),
        .rst_n (core_rst_n),
        .decode (decode),
        .op (op),
        .wb (wb)
    );

    // 4. ALU & PC (Execution & Control)
    wire alu_updates_nzp;
    wire [2:0] next_nzp0;
    wire [2:0] next_nzp1;
    wire is_exit;
    wire is_branch;
    wire is_sync;

    alu_int32 u_alu_int32 (
        .clk (clk),
        .rst_n (core_rst_n),
        .op (op),
        .wb (alu_wb),
        .alu_updates_nzp (alu_updates_nzp),
        .next_nzp0 (next_nzp0),
        .next_nzp1 (next_nzp1),
        .is_exit (is_exit),
        .is_branch (is_branch),
        .is_sync (is_sync)
    );

    pc u_pc (
        .clk (clk),
        .rst_n (core_rst_n),
        .op (op),
        .alu_updates_nzp (alu_updates_nzp),
        .next_nzp0 (next_nzp0),
        .next_nzp1 (next_nzp1),
        .is_exit (is_exit),
        .is_branch (is_branch),
        .is_sync (is_sync),
        .ctx_wb (ctx_alu_wb)
    );

    // 5. Load/Store Unit (LSU)
    wire lsu_ready;

    lsu u_lsu (
        .clk (clk),
        .rst_n (core_rst_n),
        .op (op),
        .lsu_ready (lsu_ready),
        
        .l1_req_valid (l1_req_valid),
        .l1_req_addr (l1_req_addr),
        .l1_req_wdata (l1_req_wdata),
        .l1_req_we (l1_req_we),
        .l1_req_ready (l1_req_ready),
        .l1_rsp_valid (l1_rsp_valid),
        .l1_rsp_rdata (l1_rsp_rdata),
        
        .wb (lsu_wb),
        .ctx_wb (ctx_lsu_wb)
    );

endmodule