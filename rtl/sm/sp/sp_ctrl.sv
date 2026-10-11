`timescale 1ns / 1ps
import gpu_pkg::*;

module sp_ctrl (
    input wire clk, rst_n,
    warp_alloc_if.slave alloc,
    issue_if.master issue,
    operand_if.slave op,
    wb_if.slave alu_wb, lsu_wb,
    ctx_wb_if.slave ctx_lsu_wb,
    ctx_wb_if.master ctx_alu_wb,
    ctx_wb_if ctx_wb,
    wb_if.master wb,
    input wire [2:0] lane_nzp [0:NUM_LANES-1],
    output wire [2:0] alu_fn,
    output wire ex1_writes_reg,
    output reg ex1_valid,
    output reg [$clog2(MAX_WARPS)-1:0] ex1_warp_id,
    output reg [4:0] ex1_rd
`ifdef ENABLE_GPU_DEBUG
    , output wire [31:0] debug_warp_status, debug_warp_extra, debug_warp_states
`endif
);
    // LSU completions must be queued independently of ALU write-back. A
    // single skid entry is insufficient: while it is full, another LSU
    // response can arrive in the same cycle as an ALU result. Dropping that
    // ctx_wb pulse leaves the corresponding warp permanently in STALL.
    localparam LSU_WB_QUEUE_DEPTH = MAX_WARPS;
    localparam LSU_WB_PTR_W = (LSU_WB_QUEUE_DEPTH > 1) ? $clog2(LSU_WB_QUEUE_DEPTH) : 1;
    localparam LSU_WB_COUNT_W = $clog2(LSU_WB_QUEUE_DEPTH + 1);

    reg [LSU_WB_PTR_W-1:0] lsu_wb_wr_ptr;
    reg [LSU_WB_PTR_W-1:0] lsu_wb_rd_ptr;
    reg [LSU_WB_COUNT_W-1:0] lsu_wb_count;
    reg lsu_wb_valid_q [0:LSU_WB_QUEUE_DEPTH-1];
    reg [$clog2(MAX_WARPS)-1:0] lsu_wb_warp_id_q [0:LSU_WB_QUEUE_DEPTH-1];
    reg [4:0] lsu_wb_rd_q [0:LSU_WB_QUEUE_DEPTH-1];
    reg [32*NUM_LANES-1:0] lsu_wb_data_q [0:LSU_WB_QUEUE_DEPTH-1];
    reg [31:0] lsu_wb_mask_q [0:LSU_WB_QUEUE_DEPTH-1];
    reg lsu_ctx_valid_q [0:LSU_WB_QUEUE_DEPTH-1];
    reg [$clog2(MAX_WARPS)-1:0] lsu_ctx_warp_id_q [0:LSU_WB_QUEUE_DEPTH-1];
    reg [11:0] lsu_ctx_next_pc_q [0:LSU_WB_QUEUE_DEPTH-1];

    wire alu_active = alu_wb.valid || ctx_alu_wb.valid;
    wire lsu_completion_in = lsu_wb.valid || ctx_lsu_wb.valid;
    wire lsu_queue_full = (lsu_wb_count == LSU_WB_QUEUE_DEPTH);
    wire lsu_queue_empty = (lsu_wb_count == 0);
    wire lsu_queue_pop = !lsu_queue_empty && !alu_active;
    wire lsu_queue_push = lsu_completion_in && !lsu_queue_full;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lsu_wb_wr_ptr <= '0;
            lsu_wb_rd_ptr <= '0;
            lsu_wb_count <= '0;
            for (int q = 0; q < LSU_WB_QUEUE_DEPTH; q = q + 1) begin
                lsu_wb_valid_q[q] <= 1'b0;
                lsu_ctx_valid_q[q] <= 1'b0;
            end
        end else begin
            if (lsu_queue_push) begin
                lsu_wb_valid_q[lsu_wb_wr_ptr] <= lsu_wb.valid;
                lsu_wb_warp_id_q[lsu_wb_wr_ptr] <= lsu_wb.warp_id;
                lsu_wb_rd_q[lsu_wb_wr_ptr] <= lsu_wb.rd;
                lsu_wb_data_q[lsu_wb_wr_ptr] <= lsu_wb.data;
                lsu_wb_mask_q[lsu_wb_wr_ptr] <= lsu_wb.mask;
                lsu_ctx_valid_q[lsu_wb_wr_ptr] <= ctx_lsu_wb.valid;
                lsu_ctx_warp_id_q[lsu_wb_wr_ptr] <= ctx_lsu_wb.warp_id;
                lsu_ctx_next_pc_q[lsu_wb_wr_ptr] <= ctx_lsu_wb.next_pc;
                lsu_wb_wr_ptr <= lsu_wb_wr_ptr + 1'b1;
            end
            if (lsu_queue_pop)
                lsu_wb_rd_ptr <= lsu_wb_rd_ptr + 1'b1;

            case ({lsu_queue_push, lsu_queue_pop})
                2'b10: lsu_wb_count <= lsu_wb_count + 1'b1;
                2'b01: lsu_wb_count <= lsu_wb_count - 1'b1;
                default: lsu_wb_count <= lsu_wb_count;
            endcase
        end
    end

    wire eff_lsu_wb_valid = !lsu_queue_empty && lsu_wb_valid_q[lsu_wb_rd_ptr];
    wire eff_ctx_lsu_wb_valid = !lsu_queue_empty && lsu_ctx_valid_q[lsu_wb_rd_ptr];

    assign wb.valid   = alu_active ? alu_wb.valid : eff_lsu_wb_valid;
    assign wb.warp_id = alu_wb.valid ? alu_wb.warp_id : lsu_wb_warp_id_q[lsu_wb_rd_ptr];
    assign wb.rd      = alu_wb.valid ? alu_wb.rd : lsu_wb_rd_q[lsu_wb_rd_ptr];
    assign wb.data    = alu_wb.valid ? alu_wb.data : lsu_wb_data_q[lsu_wb_rd_ptr];
    assign wb.mask    = alu_wb.valid ? alu_wb.mask : lsu_wb_mask_q[lsu_wb_rd_ptr];
    
    assign ctx_wb.valid          = alu_wb.valid || ctx_alu_wb.valid ? ctx_alu_wb.valid : eff_ctx_lsu_wb_valid;
    assign ctx_wb.warp_id        = alu_wb.valid || ctx_alu_wb.valid ? ctx_alu_wb.warp_id : lsu_ctx_warp_id_q[lsu_wb_rd_ptr];
    assign ctx_wb.next_pc        = alu_wb.valid || ctx_alu_wb.valid ? ctx_alu_wb.next_pc : lsu_ctx_next_pc_q[lsu_wb_rd_ptr];
    assign ctx_wb.is_done        = alu_wb.valid || ctx_alu_wb.valid ? ctx_alu_wb.is_done : 1'b0;
    assign ctx_wb.taken_mask     = alu_wb.valid || ctx_alu_wb.valid ? ctx_alu_wb.taken_mask : 32'd0;
    assign ctx_wb.not_taken_mask = alu_wb.valid || ctx_alu_wb.valid ? ctx_alu_wb.not_taken_mask : 32'd0;
    assign ctx_wb.is_divergent   = alu_wb.valid || ctx_alu_wb.valid ? ctx_alu_wb.is_divergent : 1'b0;
    assign ctx_wb.is_sync        = alu_wb.valid || ctx_alu_wb.valid ? ctx_alu_wb.is_sync : 1'b0;
    assign ctx_wb.is_ssy         = alu_wb.valid || ctx_alu_wb.valid ? ctx_alu_wb.is_ssy : 1'b0;
    assign ctx_wb.target_pc      = alu_wb.valid || ctx_alu_wb.valid ? ctx_alu_wb.target_pc : 12'd0;

    // 1. Warp Context & Dynamic Scheduler
    warp_context u_warp_context (
        .clk (clk),
        .rst_n (rst_n),
        .alloc (alloc),
        // Each cycle, warp_context picks ONE warp in STATE_READY, issues its instruction,
        // and immediately sets that warp to STATE_STALL until retired by ctx_wb.
        // - Intra-warp: Exactly 1 instruction in flight per warp, eliminating the need 
        //   for complex forwarding/bypass networks or intra-warp hazard units.
        // - Inter-warp: The pipeline datapath can still hold multiple instructions across
        //   different stages simultaneously, as long as they belong to DIFFERENT warps 
        //   (fine-grained multithreading / barrel execution to hide latency).
        .issue (issue),
        .ctx_wb (ctx_wb)
`ifdef ENABLE_GPU_DEBUG
        ,
        .debug_warp_status (debug_warp_status),
        .debug_warp_extra (debug_warp_extra),
        .debug_warp_states (debug_warp_states)
`endif
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
    localparam OP_SSY  = 8'hE1;
    localparam OP_EXIT = 8'hFF;

    // Warp-level EX1 Stage Registers
    reg [7:0] ex1_opcode;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
    wire is_ssy    = ex1_valid && (ex1_opcode == OP_SSY);
    wire alu_writes_reg = (ex1_opcode == OP_ADD || ex1_opcode == OP_ADDI || ex1_opcode == OP_SUB || ex1_opcode == OP_MUL || ex1_opcode == OP_S2R);


    // Decode once per warp; all lanes share the same arithmetic function.
    assign alu_fn = (op.opcode == OP_ADD || op.opcode == OP_ADDI) ? 3'd0 :
                    (op.opcode == OP_SUB || op.opcode == OP_CMP) ? 3'd1 :
                    (op.opcode == OP_MUL) ? 3'd2 : 3'd3;
    assign ex1_writes_reg = alu_writes_reg;
    // PC Module Instantiation
    pc u_pc (
        .clk             (clk),
        .rst_n           (rst_n),
        .op              (op),
        .alu_updates_nzp (alu_updates_nzp),
        .next_nzp        (lane_nzp),
        .is_exit         (is_exit),
        .is_branch       (is_branch),
        .is_sync         (is_sync),
        .is_ssy          (is_ssy),
        .ctx_wb          (ctx_alu_wb)
    );

endmodule
