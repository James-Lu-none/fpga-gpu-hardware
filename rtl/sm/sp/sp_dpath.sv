`timescale 1ns / 1ps
`include "gpu_defines.vh"

module sp_dpath (
    input wire clk, rst_n,
    input wire [15:0] block_dim_x,
    input wire iram_we,
    input wire [11:0] iram_waddr,
    input wire [31:0] iram_wdata,
    issue_if.slave issue,
    operand_if.master op,
    wb_if.slave wb,
    wb_if.master alu_wb, lsu_wb,
    ctx_wb_if.master ctx_lsu_wb,
    input wire [2:0] alu_fn,
    input wire ex1_valid, ex1_writes_reg,
    input wire [$clog2(`MAX_WARPS)-1:0] ex1_warp_id,
    input wire [4:0] ex1_rd,
    // Interface to SM-Level Dynamic Coalescing Engine
    output wire                          mem_req_valid,
    output wire                          mem_req_is_load,
    output wire [$clog2(`MAX_WARPS)-1:0] mem_req_warp_id,
    output wire [4:0]                    mem_req_rd,
    output wire [11:0]                   mem_req_pc,
    output wire [`NUM_LANES-1:0]         mem_req_mask,
    output wire [`WARP_DATA_W-1:0]       mem_req_addr,
    output wire [`WARP_DATA_W-1:0]       mem_req_wdata,
    input  wire                          mem_req_ready,

    input  wire                          mem_rsp_valid,
    input  wire [$clog2(`MAX_WARPS)-1:0] mem_rsp_warp_id,
    input  wire [4:0]                    mem_rsp_rd,
    input  wire [11:0]                   mem_rsp_pc,
    input  wire [`NUM_LANES-1:0]         mem_rsp_mask,
    input  wire                          mem_rsp_is_load,
    input  wire [`WARP_DATA_W-1:0]       mem_rsp_rdata
`ifdef ENABLE_GPU_DEBUG
    , output wire [`PERF_COUNT-1:0] perf_events
`endif
);
    decode_if decode();
    // This block produces operands for its parent and consumes them locally.
    // A private interface keeps child slave ports off the output modport.
    operand_if operands();
    assign op.valid = operands.valid;
    assign op.warp_id = operands.warp_id;
    assign op.pc = operands.pc;
    assign op.active_mask = operands.active_mask;
    assign op.block_idx_x = operands.block_idx_x;
    assign op.block_idx_y = operands.block_idx_y;
    assign op.thread_id_start = operands.thread_id_start;
    assign op.opcode = operands.opcode;
    assign op.rd = operands.rd;
    assign op.imm = operands.imm;
    assign op.is_imm = operands.is_imm;
    assign op.rs1_data = operands.rs1_data;
    assign op.rs2_data = operands.rs2_data;


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
        .op (operands),
        .wb (wb)
    );

    // Two execution stages: partial products, then low-32-bit accumulation.
    // Other ALU operations are delayed to the same completion cycle.
    reg [31:0] ex1_add [0:`NUM_LANES-1];
    reg [31:0] ex1_sub [0:`NUM_LANES-1];
    reg [31:0] ex1_logic [0:`NUM_LANES-1];
    wire [31:0] ex2_mul [0:`NUM_LANES-1];
    reg [31:0] ex2_add [0:`NUM_LANES-1], ex2_sub [0:`NUM_LANES-1], ex2_special [0:`NUM_LANES-1], ex2_logic [0:`NUM_LANES-1];
    reg [2:0] ex2_fn;
    reg [31:0] ex2_mask;
    reg [31:0] ex1_special [0:`NUM_LANES-1];
    reg [2:0] ex1_fn;
    reg [31:0] ex1_mask;
    wire [31:0] lane_result [0:`NUM_LANES-1];
    always @(posedge clk) begin
        ex1_fn <= alu_fn;
        ex1_mask <= op.active_mask;
        ex2_fn <= ex1_fn;
        ex2_mask <= ex1_mask;
    end

    // High-fanout control buffers for wide SIMT lane array
    (* max_fanout = 16 *) wire [7:0]  dpath_opcode          = op.opcode;
    (* max_fanout = 16 *) wire [31:0] dpath_imm             = op.imm;
    (* max_fanout = 16 *) wire        dpath_is_imm          = op.is_imm;
    (* max_fanout = 16 *) wire [15:0] dpath_block_idx_x     = op.block_idx_x;
    (* max_fanout = 16 *) wire [15:0] dpath_block_idx_y     = op.block_idx_y;
    (* max_fanout = 16 *) wire [15:0] dpath_thread_id_start = op.thread_id_start;

    for (genvar k = 0; k < `NUM_LANES; k = k + 1) begin : gen_alu_lanes
        wire [31:0] a = op.rs1_data[k*32 +: 32];
        wire [31:0] rs2 = op.rs2_data[k*32 +: 32];
        // Only ADDI uses an immediate. Keep opcode-controlled muxing off MUL.
        wire [31:0] add_b = dpath_is_imm ? dpath_imm : rs2;
        wire [31:0] add_result, sub_result;
        alu_int32 u_add (.fn(3'd0), .a(a), .b(add_b), .result(add_result), .nzp());
        alu_int32 u_sub (.fn(3'd1), .a(a), .b(rs2), .result(sub_result), .nzp());
        alu_int32_mul u_mul (.clk(clk), .a(a), .b(rs2), .result(ex2_mul[k]));

        // Logic & Comparison Operations (AND, OR, XOR, SETCC)
        wire signed [31:0] s_a = a;
        wire signed [31:0] s_b = rs2;
        wire [2:0] s_nzp = {s_a < s_b, s_a == s_b, s_a > s_b};
        wire [2:0] setcc_cond = dpath_imm[8:6];
        wire [31:0] setcc_result = (|(s_nzp & setcc_cond)) ? 32'd1 : 32'd0;

        reg [31:0] logic_result;
        always @(*) begin
            case (dpath_opcode)
                8'h05: logic_result = a & rs2;
                8'h06: logic_result = a | rs2;
                8'h07: logic_result = a ^ rs2;
                8'h08: logic_result = setcc_result;
                default: logic_result = 32'd0;
            endcase
        end

        wire [15:0] linear_tid = dpath_thread_id_start + 16'(k);
        reg [15:0] tid_x_k;
        reg [15:0] tid_y_k;
        always @(*) begin
            case (block_dim_x)
                16'd1:   begin tid_x_k = 16'd0; tid_y_k = linear_tid; end
                16'd2:   begin tid_x_k = {15'd0, linear_tid[0]}; tid_y_k = {1'd0, linear_tid[15:1]}; end
                16'd4:   begin tid_x_k = {14'd0, linear_tid[1:0]}; tid_y_k = {2'd0, linear_tid[15:2]}; end
                16'd8:   begin tid_x_k = {13'd0, linear_tid[2:0]}; tid_y_k = {3'd0, linear_tid[15:3]}; end
                16'd16:  begin tid_x_k = {12'd0, linear_tid[3:0]}; tid_y_k = {4'd0, linear_tid[15:4]}; end
                16'd32:  begin tid_x_k = {11'd0, linear_tid[4:0]}; tid_y_k = {5'd0, linear_tid[15:5]}; end
                default: begin
                    tid_x_k = linear_tid;
                    tid_y_k = 16'd0;
                end
            endcase
        end

        reg [31:0] special;
        always @(*) begin
            special = 32'd0;
            if (dpath_opcode == 8'hB0) begin
                case (dpath_imm)
                    32'd0: special = {16'd0, tid_x_k};
                    32'd1: special = {16'd0, tid_y_k};
                    32'd2: special = {16'd0, dpath_block_idx_x};
                    32'd3: special = {16'd0, dpath_block_idx_y};
                    default: special = 32'd0;
                endcase
            end
        end
        // Payload is consumed only with the reset-cleared, aligned valid signal.
        // No reset on arithmetic data: reduce reset fanout and permit DSP registers.
        always @(posedge clk) begin
            ex1_add[k] <= add_result;
            ex1_sub[k] <= sub_result;
            ex1_logic[k] <= logic_result;
            ex2_add[k] <= ex1_add[k];
            ex2_sub[k] <= ex1_sub[k];
            ex2_logic[k] <= ex1_logic[k];
            ex2_special[k] <= ex1_special[k];
            ex1_special[k] <= special;
        end
        assign lane_result[k] = ex2_fn == 3'd0 ? ex2_add[k] :
                                ex2_fn == 3'd1 ? ex2_sub[k] :
                                ex2_fn == 3'd2 ? ex2_mul[k] :
                                ex2_fn == 3'd3 ? ex2_special[k] : ex2_logic[k];
    end
    // EX3 Stage: Vector Write-Back Assembly
    // Only alu_wb.valid requires asynchronous reset. Keeping high-fanout payload
    // registers (alu_wb.data, mask, rd, warp_id) off the async reset tree eliminates
    // recovery timing violations.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alu_wb.valid <= 1'b0;
        end else begin
            alu_wb.valid <= ex1_valid && ex1_writes_reg && (ex1_rd != 5'd0);
        end
    end

    always @(posedge clk) begin
        if (ex1_valid && ex1_writes_reg && (ex1_rd != 5'd0)) begin
            alu_wb.warp_id <= ex1_warp_id;
            alu_wb.rd      <= ex1_rd;
            alu_wb.mask    <= ex2_mask;
            for (int k = 0; k < `NUM_LANES; k = k + 1) begin
                alu_wb.data[k*32 +: 32] <= lane_result[k];
            end
        end
    end

    // 5. Load/Store Unit (LSU)
    wire lsu_ready;

    lsu u_lsu (
        .clk (clk),
        .rst_n (rst_n),
        .op (operands),
        .lsu_ready (lsu_ready),

        .mem_req_valid (mem_req_valid),
        .mem_req_is_load (mem_req_is_load),
        .mem_req_warp_id (mem_req_warp_id),
        .mem_req_rd (mem_req_rd),
        .mem_req_pc (mem_req_pc),
        .mem_req_mask (mem_req_mask),
        .mem_req_addr (mem_req_addr),
        .mem_req_wdata (mem_req_wdata),
        .mem_req_ready (mem_req_ready),

        .mem_rsp_valid (mem_rsp_valid),
        .mem_rsp_warp_id (mem_rsp_warp_id),
        .mem_rsp_rd (mem_rsp_rd),
        .mem_rsp_pc (mem_rsp_pc),
        .mem_rsp_mask (mem_rsp_mask),
        .mem_rsp_is_load (mem_rsp_is_load),
        .mem_rsp_rdata (mem_rsp_rdata),

        .wb (lsu_wb),
        .ctx_wb (ctx_lsu_wb)
`ifdef ENABLE_GPU_DEBUG
        , .perf_events(perf_events)
`endif
    );

endmodule
