`timescale 1ns / 1ps
// Sub-Partition Load/Store Unit (LSU)
//
// Features:
// 1. Decoupled Memory Pipeline: Buffers dispatched vector memory operations
//    in a local FIFO, releasing the instruction issue pipeline.
// 2. SM-Level Offloading: Hands over full-warp memory requests to the
//    SM Dynamic Coalescing Engine.
// 3. Zero-Overhead Writeback: Combinationally forwards coalesced vector
//    read data and warp context completion directly to the VRF and Warp Scheduler.

`include "gpu_defines.vh"

module lsu (
    input wire clk,
    input wire rst_n,

    // Operand Interface (From Dispatcher / Operand Collector)
    operand_if.slave op,
    output wire lsu_ready,

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
    input  wire [`WARP_DATA_W-1:0]       mem_rsp_rdata,

    // Write-Back Interface to Vector Register File
    wb_if.master wb,

    // Write-Back Interface to Warp Context Scheduler
    ctx_wb_if.master ctx_wb

`ifdef ENABLE_GPU_DEBUG
    , output reg [`PERF_COUNT-1:0] perf_events
`endif
);

    localparam OP_LDR = 8'hA0;
    localparam OP_STR = 8'hA1;

    localparam FIFO_DEPTH = `MAX_WARPS;
    localparam FIFO_PTR_W = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;

    // -------------------------------------------------------------------------
    // Context Interface Defaults
    // -------------------------------------------------------------------------
    assign ctx_wb.is_done       = 1'b0;
    assign ctx_wb.is_divergent  = 1'b0;
    assign ctx_wb.taken_mask    = '0;
    assign ctx_wb.not_taken_mask= '0;
    assign ctx_wb.is_sync       = 1'b0;
    assign ctx_wb.is_ssy        = 1'b0;
    assign ctx_wb.target_pc     = '0;

    // -------------------------------------------------------------------------
    // FIFO Control Registers (Asynchronous Reset)
    // -------------------------------------------------------------------------
    reg [FIFO_PTR_W-1:0]           fifo_wr_ptr;
    reg [FIFO_PTR_W-1:0]           fifo_rd_ptr;
    reg [$clog2(FIFO_DEPTH+1)-1:0] fifo_count;

    // -------------------------------------------------------------------------
    // FIFO Payload Storage (Synchronous Unreset to Minimize FPGA Resources)
    // -------------------------------------------------------------------------
    reg                          fifo_is_load [0:FIFO_DEPTH-1];
    reg [$clog2(`MAX_WARPS)-1:0] fifo_warp_id [0:FIFO_DEPTH-1];
    reg [4:0]                    fifo_rd      [0:FIFO_DEPTH-1];
    reg [11:0]                   fifo_pc      [0:FIFO_DEPTH-1];
    reg [`NUM_LANES-1:0]         fifo_mask    [0:FIFO_DEPTH-1];
    reg [`WARP_DATA_W-1:0]       fifo_addr    [0:FIFO_DEPTH-1];
    reg [`WARP_DATA_W-1:0]       fifo_wdata   [0:FIFO_DEPTH-1];

    wire op_is_mem   = op.valid && (op.opcode == OP_LDR || op.opcode == OP_STR);
    wire fifo_push   = op_is_mem && (fifo_count < FIFO_DEPTH);
    wire fifo_pop    = mem_req_valid && mem_req_ready;

    assign lsu_ready = (fifo_count < FIFO_DEPTH);

    // -------------------------------------------------------------------------
    // Memory Request Generation (Head of FIFO)
    // -------------------------------------------------------------------------
    assign mem_req_valid   = (fifo_count != 0);
    assign mem_req_is_load = fifo_is_load[fifo_rd_ptr];
    assign mem_req_warp_id = fifo_warp_id[fifo_rd_ptr];
    assign mem_req_rd      = fifo_rd[fifo_rd_ptr];
    assign mem_req_pc      = fifo_pc[fifo_rd_ptr];
    assign mem_req_mask    = fifo_mask[fifo_rd_ptr];
    assign mem_req_addr    = fifo_addr[fifo_rd_ptr];
    assign mem_req_wdata   = fifo_wdata[fifo_rd_ptr];

    // -------------------------------------------------------------------------
    // FIFO Control Update
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
            fifo_count  <= '0;
        end else begin
            if (fifo_push)
                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;

            if (fifo_pop)
                fifo_rd_ptr <= fifo_rd_ptr + 1'b1;

            case ({fifo_push, fifo_pop})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // FIFO Payload Writing
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (fifo_push) begin
            fifo_is_load[fifo_wr_ptr] <= (op.opcode == OP_LDR);
            fifo_warp_id[fifo_wr_ptr] <= op.warp_id;
            fifo_rd[fifo_wr_ptr]      <= op.rd;
            fifo_pc[fifo_wr_ptr]      <= op.pc;
            fifo_mask[fifo_wr_ptr]    <= op.active_mask[`NUM_LANES-1:0];
            fifo_addr[fifo_wr_ptr]    <= op.rs1_data;
            fifo_wdata[fifo_wr_ptr]   <= op.rs2_data;
        end
    end

    // -------------------------------------------------------------------------
    // Writeback Forwarding to VRF and Warp Scheduler
    // -------------------------------------------------------------------------
    assign wb.valid   = mem_rsp_valid && mem_rsp_is_load && (mem_rsp_rd != 5'd0);
    assign wb.warp_id = mem_rsp_warp_id;
    assign wb.rd      = mem_rsp_rd;
    assign wb.mask    = 32'(mem_rsp_mask);
    assign wb.data    = mem_rsp_rdata;

    assign ctx_wb.valid   = mem_rsp_valid;
    assign ctx_wb.warp_id = mem_rsp_warp_id;
    assign ctx_wb.next_pc = mem_rsp_pc + 12'd1;

`ifdef ENABLE_GPU_DEBUG
    always_comb begin
        perf_events = '0;
        perf_events[`PERF_LSU_FIFO_FULL_CYCLES] = (fifo_count == FIFO_DEPTH);
    end
`endif

endmodule
