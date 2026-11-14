`timescale 1ns / 1ps
// Dynamic Coalescing Engine (SM Level)
//
// Features:
// 1. SM-Level Memory Consolidation: Sits between all Sub-Partitions (SPs)
//    and the shared L1 Data Cache, replacing per-SP coalescing duplicates.
// 2. Wide L1 Cache Interface: Communicates with L1 cache using DATA_W_L1
//    (e.g., 256 bits = 32 bytes) for maximum cache-line transfer bandwidth.
// 3. Dynamic Cache-Line Coalescing:
//    - Analyzes SIMT lane addresses across the active warp.
//    - Coalesces all lanes accessing the same DATA_W_L1 cache line into a
//      single multi-word memory transaction with precise byte strobes.
//    - Sequential 16-lane accesses require only 2 transactions instead of 8 or 16.
//    - Uniform (broadcast / scalar) accesses require only 1 transaction.
//    - Divergent accesses across cache lines are serialized into minimal transactions.
// 4. Parallel Vector Assembly & Writeback:
//    - Gathers load responses into a full WARP_DATA_W (e.g. 512-bit) vector.
//    - Routes responses directly back to the requesting Sub-Partition.

`include "gpu_defines.vh"

module dynamic_coalescing_engine (
    input  wire                              clk,
    input  wire                              rst_n,

    // Sub-Partition Request Interfaces (from NUM_SPS clients)
    input  wire [`NUM_SPS-1:0]               sp_req_valid,
    input  wire [`NUM_SPS-1:0]               sp_req_is_load,
    input  wire [$clog2(`MAX_WARPS)-1:0]     sp_req_warp_id [0:`NUM_SPS-1],
    input  wire [4:0]                        sp_req_rd      [0:`NUM_SPS-1],
    input  wire [11:0]                       sp_req_pc      [0:`NUM_SPS-1],
    input  wire [`NUM_LANES-1:0]             sp_req_mask    [0:`NUM_SPS-1],
    input  wire [`WARP_DATA_W-1:0]           sp_req_addr    [0:`NUM_SPS-1],
    input  wire [`WARP_DATA_W-1:0]           sp_req_wdata   [0:`NUM_SPS-1],
    output wire [`NUM_SPS-1:0]               sp_req_ready,

    // Sub-Partition Response Interfaces (to NUM_SPS clients)
    output reg  [`NUM_SPS-1:0]               sp_rsp_valid,
    output reg  [$clog2(`MAX_WARPS)-1:0]     sp_rsp_warp_id [0:`NUM_SPS-1],
    output reg  [4:0]                        sp_rsp_rd      [0:`NUM_SPS-1],
    output reg  [11:0]                       sp_rsp_pc      [0:`NUM_SPS-1],
    output reg  [`NUM_LANES-1:0]             sp_rsp_mask    [0:`NUM_SPS-1],
    output reg  [`NUM_SPS-1:0]               sp_rsp_is_load,
    output reg  [`WARP_DATA_W-1:0]           sp_rsp_rdata   [0:`NUM_SPS-1],

    // L1 Cache Interface (Wide DATA_W_L1)
    output reg                               l1_req_valid,
    output reg  [31:0]                       l1_req_addr,
    output reg  [`DATA_W_L1-1:0]             l1_req_wdata,
    output reg  [`STRB_W_L1-1:0]             l1_req_wstrb,
    output reg                               l1_req_we,
    input  wire                              l1_req_ready,
    input  wire                              l1_rsp_valid,
    input  wire [`DATA_W_L1-1:0]             l1_rsp_rdata

`ifdef ENABLE_GPU_DEBUG
    , output reg [`PERF_COUNT-1:0]       perf_events
`endif
);

    localparam ST_IDLE  = 2'd0;
    localparam ST_ISSUE = 2'd1;
    localparam ST_WAIT  = 2'd2;

    localparam SP_IDX_W       = (`NUM_SPS > 1) ? $clog2(`NUM_SPS) : 1;
    localparam LANE_IDX_W     = (`NUM_LANES > 1) ? $clog2(`NUM_LANES) : 1;
    localparam LINE_BYTES     = `DATA_W_L1 / 8;
    localparam OFFSET_BITS    = $clog2(LINE_BYTES);
    localparam TAG_BITS       = 32 - OFFSET_BITS;
    localparam WORDS_PER_LINE = `DATA_W_L1 / 32;
    localparam WORD_IDX_BITS  = (WORDS_PER_LINE > 1) ? $clog2(WORDS_PER_LINE) : 1;

    // -------------------------------------------------------------------------
    // Helper Functions (Word-Parallel Mapping)
    // -------------------------------------------------------------------------
    function automatic logic [LANE_IDX_W-1:0] get_first_set(
        input logic [`NUM_LANES-1:0] mask
    );
        logic [LANE_IDX_W-1:0] idx;
        begin
            idx = '0;
            for (int i = `NUM_LANES - 1; i >= 0; i--) begin
                if (mask[i]) begin
                    idx = LANE_IDX_W'(i);
                end
            end
            return idx;
        end
    endfunction

    function automatic logic [`NUM_LANES-1:0] compute_line_coal_mask(
        input logic [`NUM_LANES-1:0]   mask,
        input logic [`WARP_DATA_W-1:0] addrs,
        input logic [LANE_IDX_W-1:0]  base_idx
    );
        logic [`NUM_LANES-1:0] coal;
        logic [TAG_BITS-1:0]  base_tag;
        begin
            base_tag = addrs[32'(base_idx)*32 + OFFSET_BITS +: TAG_BITS];
            coal = '0;
            for (int i = 0; i < `NUM_LANES; i++) begin
                if (mask[i] && (addrs[32'(i)*32 + OFFSET_BITS +: TAG_BITS] == base_tag)) begin
                    coal[i] = 1'b1;
                end
            end
            return coal;
        end
    endfunction

    function automatic logic [`STRB_W_L1-1:0] compute_line_wstrb(
        input logic [`NUM_LANES-1:0]   coal_mask,
        input logic [`WARP_DATA_W-1:0] addrs
    );
        logic [`STRB_W_L1-1:0] strb;
        begin
            strb = '0;
            for (int w = 0; w < WORDS_PER_LINE; w++) begin
                logic word_valid;
                word_valid = 1'b0;
                for (int i = 0; i < `NUM_LANES; i++) begin
                    if (coal_mask[i] && (addrs[32'(i)*32 + 2 +: WORD_IDX_BITS] == WORD_IDX_BITS'(w))) begin
                        word_valid = 1'b1;
                    end
                end
                strb[w*4 +: 4] = word_valid ? 4'hF : 4'h0;
            end
            return strb;
        end
    endfunction

    function automatic logic [`DATA_W_L1-1:0] compute_line_wdata(
        input logic [`NUM_LANES-1:0]   coal_mask,
        input logic [`WARP_DATA_W-1:0] addrs,
        input logic [`WARP_DATA_W-1:0] wdatas
    );
        logic [`DATA_W_L1-1:0] wdata;
        begin
            wdata = '0;
            for (int w = 0; w < WORDS_PER_LINE; w++) begin
                logic [31:0] word_val;
                word_val = 32'd0;
                for (int i = 0; i < `NUM_LANES; i++) begin
                    if (coal_mask[i] && (addrs[32'(i)*32 + 2 +: WORD_IDX_BITS] == WORD_IDX_BITS'(w))) begin
                        word_val = wdatas[32'(i)*32 +: 32];
                    end
                end
                wdata[w*32 +: 32] = word_val;
            end
            return wdata;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Round-Robin Sub-Partition Arbitration
    // -------------------------------------------------------------------------
    reg [SP_IDX_W-1:0] rr_ptr;
    reg [SP_IDX_W-1:0] sel_sp;
    reg client_found;

    always_comb begin
        sel_sp       = rr_ptr;
        client_found = 1'b0;
        for (int c = 0; c < `NUM_SPS; c = c + 1) begin
            int idx;
            idx = (32'(rr_ptr) + c) % `NUM_SPS;
            if (!client_found && sp_req_valid[idx]) begin
                sel_sp       = SP_IDX_W'(idx);
                client_found = 1'b1;
            end
        end
    end

    // Ready handshake: Accepted in IDLE state
    for (genvar c = 0; c < `NUM_SPS; c = c + 1) begin : gen_sp_ready
        assign sp_req_ready[c] = (state == ST_IDLE) && client_found && (sel_sp == SP_IDX_W'(c));
    end

    // -------------------------------------------------------------------------
    // Control Path Registers (Asynchronous Reset)
    // -------------------------------------------------------------------------
    reg [1:0] state;
    reg [SP_IDX_W-1:0] active_sp;
    reg [`NUM_LANES-1:0] pending_lanes;
    reg [`NUM_LANES-1:0] active_coal_mask;

    // -------------------------------------------------------------------------
    // Datapath Payload Registers (Synchronous Unreset)
    // -------------------------------------------------------------------------
    reg                         active_is_load;
    reg [$clog2(`MAX_WARPS)-1:0] active_warp_id;
    reg [4:0]                   active_rd;
    reg [11:0]                  active_pc;
    reg [`NUM_LANES-1:0]         active_mask;
    reg [`WARP_DATA_W-1:0]       active_addr;
    reg [`WARP_DATA_W-1:0]       active_wdata;
    reg [`WARP_DATA_W-1:0]       gathered_rdata;

    // Combinational evaluation of next coalesced transaction from active_addr
    wire [LANE_IDX_W-1:0] next_base_lane = get_first_set(pending_lanes);
    wire [`NUM_LANES-1:0]  next_coal_mask = compute_line_coal_mask(pending_lanes, active_addr, next_base_lane);

    // -------------------------------------------------------------------------
    // State Machine & Transaction Dispatch
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            rr_ptr           <= '0;
            active_sp        <= '0;
            pending_lanes    <= '0;
            active_coal_mask <= '0;
            l1_req_valid     <= 1'b0;
            sp_rsp_valid     <= '0;
        end else begin
            sp_rsp_valid <= '0;

            case (state)
                ST_IDLE: begin
                    if (client_found) begin
                        if (sp_req_mask[sel_sp] == '0) begin
                            // Inactive warp: immediately complete without memory transaction
                            sp_rsp_valid[sel_sp]   <= 1'b1;
                            sp_rsp_warp_id[sel_sp] <= sp_req_warp_id[sel_sp];
                            sp_rsp_rd[sel_sp]      <= sp_req_rd[sel_sp];
                            sp_rsp_pc[sel_sp]      <= sp_req_pc[sel_sp];
                            sp_rsp_mask[sel_sp]    <= '0;
                            sp_rsp_is_load[sel_sp] <= sp_req_is_load[sel_sp];
                            sp_rsp_rdata[sel_sp]   <= '0;
                            rr_ptr                 <= SP_IDX_W'((32'(sel_sp) + 1) % `NUM_SPS);
                            state                  <= ST_IDLE;
                        end else begin
                            // Latch request into registers
                            active_sp        <= sel_sp;
                            active_is_load   <= sp_req_is_load[sel_sp];
                            active_warp_id   <= sp_req_warp_id[sel_sp];
                            active_rd        <= sp_req_rd[sel_sp];
                            active_pc        <= sp_req_pc[sel_sp];
                            active_mask      <= sp_req_mask[sel_sp];
                            active_addr      <= sp_req_addr[sel_sp];
                            active_wdata     <= sp_req_wdata[sel_sp];
                            pending_lanes    <= sp_req_mask[sel_sp];

                            state            <= ST_ISSUE;
                        end
                    end
                end

                ST_ISSUE: begin
                    if (!l1_req_valid) begin
                        // Dispatch next coalesced line from active_addr
                        l1_req_addr      <= {active_addr[32'(next_base_lane)*32 + OFFSET_BITS +: TAG_BITS], {OFFSET_BITS{1'b0}}};
                        l1_req_we        <= !active_is_load;
                        l1_req_wstrb     <= compute_line_wstrb(next_coal_mask, active_addr);
                        l1_req_wdata     <= compute_line_wdata(next_coal_mask, active_addr, active_wdata);
                        l1_req_valid     <= 1'b1;
                        active_coal_mask <= next_coal_mask;
                        pending_lanes    <= pending_lanes & ~next_coal_mask;
                    end else if (l1_req_ready) begin
                        l1_req_valid <= 1'b0;
                        state        <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (l1_rsp_valid) begin
                        // Save returned data for current coalesced lanes
                        if (active_is_load) begin
                            for (int k = 0; k < `NUM_LANES; k = k + 1) begin
                                if (active_coal_mask[k]) begin
                                    logic [WORD_IDX_BITS-1:0] w_idx;
                                    w_idx = active_addr[32'(k)*32 + 2 +: WORD_IDX_BITS];
                                    gathered_rdata[32'(k)*32 +: 32] <= l1_rsp_rdata[32'(w_idx)*32 +: 32];
                                end
                            end
                        end

                        if (pending_lanes != '0) begin
                            // Divergent memory accesses: loop back to issue remaining lines
                            state <= ST_ISSUE;
                        end else begin
                            // All lanes satisfied: assemble writeback response to Sub-Partition
                            sp_rsp_valid[active_sp]   <= 1'b1;
                            sp_rsp_warp_id[active_sp] <= active_warp_id;
                            sp_rsp_rd[active_sp]      <= active_rd;
                            sp_rsp_pc[active_sp]      <= active_pc;
                            sp_rsp_mask[active_sp]    <= active_mask;
                            sp_rsp_is_load[active_sp] <= active_is_load;

                            for (int k = 0; k < `NUM_LANES; k = k + 1) begin
                                if (active_coal_mask[k]) begin
                                    logic [WORD_IDX_BITS-1:0] w_idx;
                                    w_idx = active_addr[32'(k)*32 + 2 +: WORD_IDX_BITS];
                                    sp_rsp_rdata[active_sp][32'(k)*32 +: 32] <= l1_rsp_rdata[32'(w_idx)*32 +: 32];
                                end else begin
                                    sp_rsp_rdata[active_sp][32'(k)*32 +: 32] <= gathered_rdata[32'(k)*32 +: 32];
                                end
                            end

                            rr_ptr <= SP_IDX_W'((32'(active_sp) + 1) % `NUM_SPS);
                            state  <= ST_IDLE;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

`ifdef ENABLE_GPU_DEBUG
    always_comb begin
        perf_events = '0;
        perf_events[`PERF_LSU_WAIT_CYCLES] = (state == ST_WAIT);
    end
`endif

endmodule
