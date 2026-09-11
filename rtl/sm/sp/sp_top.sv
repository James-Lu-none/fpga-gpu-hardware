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
    output wire [DATA_W-1:0] l1_req_wdata,
    output wire l1_req_we,
    input wire l1_req_ready,
    input wire l1_rsp_valid,
    input wire [DATA_W-1:0] l1_rsp_rdata
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

    // 4. ALU & PC Execution Pipeline
    localparam OP_ADD  = 8'h01;
    localparam OP_SUB  = 8'h02;
    localparam OP_MUL  = 8'h03;
    localparam OP_CMP  = 8'h04;
    localparam OP_ADDI = 8'h81;
    localparam OP_S2R  = 8'hB0;
    localparam OP_BR   = 8'hC0;
    localparam OP_SYNC = 8'hE0;
    localparam OP_EXIT = 8'hFF;

    // Warp-level EX1 Stage Registers
    reg ex1_valid;
    reg [7:0] ex1_opcode;
    reg [$clog2(MAX_WARPS)-1:0] ex1_warp_id;
    reg [4:0] ex1_rd;

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            ex1_valid   <= 1'b0;
            ex1_opcode  <= 8'd0;
            ex1_warp_id <= '0;
            ex1_rd      <= 5'd0;
        end else begin
            ex1_valid   <= op.valid;
            ex1_opcode  <= op.opcode;
            ex1_warp_id <= op.warp_id;
            ex1_rd      <= op.rd;
        end
    end

    wire alu_updates_nzp = ex1_valid && (ex1_opcode == OP_ADD || ex1_opcode == OP_ADDI || ex1_opcode == OP_SUB || ex1_opcode == OP_CMP);
    wire is_exit   = ex1_valid && (ex1_opcode == OP_EXIT);
    wire is_branch = ex1_valid && (ex1_opcode == OP_BR);
    wire is_sync   = ex1_valid && (ex1_opcode == OP_SYNC);
    wire alu_writes_reg = (ex1_opcode == OP_ADD || ex1_opcode == OP_ADDI || ex1_opcode == OP_SUB || ex1_opcode == OP_MUL || ex1_opcode == OP_S2R);

    // Generate K ALU Lanes
    wire [31:0] lane_result [0:NUM_LANES-1];
    wire [2:0]  lane_nzp    [0:NUM_LANES-1];

    for (genvar k = 0; k < NUM_LANES; k = k + 1) begin : gen_alu_lanes
        wire [31:0] lane_rs1 = op.rs1_data[k*32 +: 32];
        wire [31:0] lane_rs2 = op.is_imm ? op.imm : op.rs2_data[k*32 +: 32];

        alu_int32 #(
            .LANE_INDEX (k)
        ) u_alu_int32 (
            .clk             (clk),
            .rst_n           (core_rst_n),
            .valid           (op.valid),
            .opcode          (op.opcode),
            .imm             (op.imm),
            .rs1_data        (lane_rs1),
            .rs2_data        (lane_rs2),
            .lane_id         (5'(k)),
            .thread_id_start (op.thread_id_start),
            .block_idx_x     (op.block_idx_x),
            .block_idx_y     (op.block_idx_y),
            .result          (lane_result[k]),
            .next_nzp        (lane_nzp[k])
        );
    end

    // EX3 Stage: Vector Write-Back Assembly
    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            alu_wb.valid   <= 1'b0;
            alu_wb.warp_id <= '0;
            alu_wb.rd      <= 5'd0;
            alu_wb.data    <= '0;
            alu_wb.mask    <= 32'd0;
        end else begin
            alu_wb.valid <= 1'b0;
            if (ex1_valid && alu_writes_reg && (ex1_rd != 5'd0)) begin
                alu_wb.valid   <= 1'b1;
                alu_wb.warp_id <= ex1_warp_id;
                alu_wb.rd      <= ex1_rd;
                alu_wb.mask    <= 32'hFFFFFFFF;
                for (int k = 0; k < NUM_LANES; k = k + 1) begin
                    alu_wb.data[k*32 +: 32] <= lane_result[k];
                end
            end
        end
    end

    // PC Module Instantiation
    pc u_pc (
        .clk             (clk),
        .rst_n           (core_rst_n),
        .op              (op),
        .alu_updates_nzp (alu_updates_nzp),
        .next_nzp0       (lane_nzp[0]),
        .next_nzp1       ((NUM_LANES > 1) ? lane_nzp[1] : 3'b000),
        .is_exit         (is_exit),
        .is_branch       (is_branch),
        .is_sync         (is_sync),
        .ctx_wb          (ctx_alu_wb)
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