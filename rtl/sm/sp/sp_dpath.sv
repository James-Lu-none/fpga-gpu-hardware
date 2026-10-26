`timescale 1ns / 1ps
import gpu_pkg::*;

module sp_dpath (
    input wire clk, rst_n,
    input wire iram_we,
    input wire [11:0] iram_waddr,
    input wire [31:0] iram_wdata,
    issue_if.slave issue,
    operand_if op,
    wb_if.slave wb,
    wb_if.master alu_wb, lsu_wb,
    ctx_wb_if.master ctx_lsu_wb,
    input wire [2:0] alu_fn,
    input wire ex1_valid, ex1_writes_reg,
    input wire [$clog2(MAX_WARPS)-1:0] ex1_warp_id,
    input wire [4:0] ex1_rd,
    output wire [2:0] lane_nzp [0:NUM_LANES-1],
    output wire l1_req_valid, l1_req_we,
    output wire [31:0] l1_req_addr,
    output wire [DATA_W-1:0] l1_req_wdata,
    output wire [7:0] l1_req_wstrb,
    input wire l1_req_ready, l1_rsp_valid,
    input wire [DATA_W-1:0] l1_rsp_rdata
`ifdef ENABLE_GPU_DEBUG
    , output wire [PERF_COUNT-1:0] perf_events
`endif
);
    decode_if decode();

    // 2. Instruction Fetch & Decode
    fetch_decode u_fetch_decode (
        .clk (clk),
        .rst_n (rst_n),
        .iram_we (iram_we),
        .iram_waddr (iram_waddr),
        .iram_wdata (iram_wdata),
        .issue (issue),
        .decode (decode)
    );

    // 3. Vector Register File (VRF)
    vector_regfile u_vector_regfile (
        .clk (clk),
        .rst_n (rst_n),
        .decode (decode),
        .op (op),
        .wb (wb)
    );

    // EX1 registers remain in the datapath, preserving arithmetic/DSP timing.
    reg [31:0] ex1_add [0:NUM_LANES-1];
    reg [31:0] ex1_sub [0:NUM_LANES-1];
    reg [31:0] ex1_mul [0:NUM_LANES-1];
    reg [31:0] ex1_special [0:NUM_LANES-1];
    reg [2:0] ex1_fn;
    reg [31:0] ex1_mask;
    wire [31:0] lane_result [0:NUM_LANES-1];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex1_fn <= 3'd3;
            ex1_mask <= 32'd0;
        end else begin
            ex1_fn <= alu_fn;
            ex1_mask <= op.active_mask;
        end
    end
    for (genvar k = 0; k < NUM_LANES; k = k + 1) begin : gen_alu_lanes
        wire [31:0] a = op.rs1_data[k*32 +: 32];
        wire [31:0] rs2 = op.rs2_data[k*32 +: 32];
        // Only ADDI uses an immediate. Keep opcode-controlled muxing off MUL.
        wire [31:0] add_b = op.is_imm ? op.imm : rs2;
        wire [31:0] add_result, sub_result, mul_result;
        alu_int32 u_add (.fn(3'd0), .a(a), .b(add_b), .result(add_result), .nzp());
        alu_int32 u_sub (.fn(3'd1), .a(a), .b(rs2), .result(sub_result), .nzp());
        alu_int32 u_mul (.fn(3'd2), .a(a), .b(rs2), .result(mul_result), .nzp());
        reg [31:0] special;
        always @(*) begin
            special = 32'd0;
            if (op.opcode == 8'hB0) begin
                case (op.imm)
                    32'd0: special = {16'd0, op.thread_id_start} + 32'(k);
                    32'd1: special = 32'd0; // local Y dimension not supported for now
                    32'd2: special = {16'd0, op.block_idx_x};
                    32'd3: special = {16'd0, op.block_idx_y};
                    default: special = 32'd0;
                endcase
            end
        end
        // Payload is consumed only with the reset-cleared EX1 valid signal.
        // No reset on arithmetic data: reduce reset fanout and permit DSP registers.
        always @(posedge clk) begin
            ex1_add[k] <= add_result;
            ex1_sub[k] <= sub_result;
            ex1_mul[k] <= mul_result;
            ex1_special[k] <= special;
        end
        assign lane_result[k] = ex1_fn == 3'd0 ? ex1_add[k] :
                                ex1_fn == 3'd1 ? ex1_sub[k] :
                                ex1_fn == 3'd2 ? ex1_mul[k] : ex1_special[k];
        assign lane_nzp[k] = {lane_result[k][31], lane_result[k] == 0,
                             !lane_result[k][31] && lane_result[k] != 0};
    end
    // EX3 Stage: Vector Write-Back Assembly
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alu_wb.valid   <= 1'b0;
            alu_wb.warp_id <= '0;
            alu_wb.rd      <= 5'd0;
            alu_wb.data    <= '0;
            alu_wb.mask    <= 32'd0;
        end else begin
            alu_wb.valid <= 1'b0;
            if (ex1_valid && ex1_writes_reg && (ex1_rd != 5'd0)) begin
                alu_wb.valid   <= 1'b1;
                alu_wb.warp_id <= ex1_warp_id;
                alu_wb.rd      <= ex1_rd;
                alu_wb.mask    <= ex1_mask;
                for (int k = 0; k < NUM_LANES; k = k + 1) begin
                    alu_wb.data[k*32 +: 32] <= lane_result[k];
                end
            end
        end
    end

    // 5. Load/Store Unit (LSU)
    wire lsu_ready;

    lsu u_lsu (
        .clk (clk),
        .rst_n (rst_n),
        .op (op),
        .lsu_ready (lsu_ready),
        
        .l1_req_valid (l1_req_valid),
        .l1_req_addr (l1_req_addr),
        .l1_req_wdata (l1_req_wdata),
        .l1_req_we (l1_req_we),
        .l1_req_wstrb (l1_req_wstrb),
        .l1_req_ready (l1_req_ready),
        .l1_rsp_valid (l1_rsp_valid),
        .l1_rsp_rdata (l1_rsp_rdata),
        
        .wb (lsu_wb),
        .ctx_wb (ctx_lsu_wb)
`ifdef ENABLE_GPU_DEBUG
        , .perf_events(perf_events)
`endif
    );

endmodule
