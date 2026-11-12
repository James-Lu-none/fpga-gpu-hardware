`timescale 1ns / 1ps

// GPU Streaming Multiprocessor (SM)
// Receives dynamic Thread Block assignments from the GigaThread Engine (TBS).
// Encapsulates M Sub-Partitions, local Thread Block Receiver, and Shared L1 Cache.

import gpu_pkg::*;

module streaming_multiprocessor #(
    parameter NUM_SPS = gpu_pkg::NUM_SUB_PARTITIONS
)(
    input wire clk,
    input wire rst_n,
    input wire flush,

    // TBS Dispatch Interface (From GPC)
    input wire block_issue_valid,
    input wire [15:0] block_idx_x,
    input wire [15:0] block_idx_y,
    input wire [9:0] warps_per_block,
    
    output wire block_accepted,
    output wire [4:0] available_warp_slots,
    output wire sm_idle,

    // Global Config & I-RAM Interface (From GPC)
    input wire [31:0] dma_src_addr,
    input wire [31:0] dma_dst_addr,
    input wire iram_we,
    input wire [11:0] iram_waddr,
    input wire [31:0] iram_wdata,

    // L1 to L2 Cache Interface
    output wire l1_req_valid,
    output wire [31:0] l1_req_addr,
    output wire [255:0]l1_req_wdata,
    output wire [31:0] l1_req_wstrb,
    output wire l1_req_we,
    input wire l1_req_ready,
    input wire l1_rsp_valid,
    input wire [255:0]l1_rsp_rdata
`ifdef ENABLE_GPU_DEBUG
    , input wire perf_clear,
    output reg [31:0] perf_increments [0:PERF_COUNT-1]
`endif
);

    // Reset Pipeline (Level 2)
    // Reset distribution stage, not a CDC synchronizer. Allow driver replication.
    reg sm_rst_n_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sm_rst_n_reg <= 1'b0;
        else        sm_rst_n_reg <= 1'b1;
    end
    wire sm_rst_n = sm_rst_n_reg;

    // 1. sm level contoller
    // collect warp allocation status from SPs
    // report available_warp_slots
    // Parallel CTA Commit Architecture:
    // Dispatches up to NUM_SPS warps in parallel across all sub-partitions simultaneously.
    // Blocks with <= NUM_SPS warps commit in exactly 1 clock cycle!
    localparam ST_IDLE      = 3'd0;
    localparam ST_COMMIT    = 3'd1;
    localparam ST_WAIT_DROP = 3'd2;

    reg [2:0]  rx_state;
    reg [15:0] accepted_block_x;
    reg [15:0] accepted_block_y;
    reg [9:0]  accepted_warps_per_block;
    reg [9:0]  warp_base;
    reg        block_accepted_reg;

    localparam SP_PTR_W = (NUM_SPS > 1) ? $clog2(NUM_SPS) : 1;
    reg [SP_PTR_W-1:0] sp_rr_ptr;

    warp_alloc_if alloc [0:NUM_SPS-1]();

    // Unpack interface signals to regular logic arrays
    // since interface array is not allow to use runtime value as index
    wire [4:0]         sp_avail_slots [0:NUM_SPS-1];
    wire [NUM_SPS-1:0] sp_alloc_ready;

    for (genvar s = 0; s < NUM_SPS; s = s + 1) begin : gen_alloc_unpack
        assign sp_avail_slots[s] = alloc[s].available_slots;
        assign sp_alloc_ready[s] = alloc[s].ready;
    end

    // Compute total available warp slots across all sub-partitions
    wire [4:0] max_free_slots;
    generate
        if (NUM_SPS == 1) begin : gen_alloc_cap_single
            assign max_free_slots = sp_avail_slots[0];
        end else begin : gen_alloc_cap_multi
            reg [5:0] total_free_slots_comb;
            always @(*) begin
                total_free_slots_comb = 6'd0;
                for (int s = 0; s < NUM_SPS; s = s + 1) begin
                    total_free_slots_comb = total_free_slots_comb + 6'(sp_avail_slots[s]);
                end
            end
            assign max_free_slots = (total_free_slots_comb > 6'd31) ? 5'd31 : total_free_slots_comb[4:0];
        end
    endgenerate

    // Current block coordinates and dimensions (pass-through in IDLE for 1-cycle commit)
    wire [15:0] cur_block_x = (rx_state == ST_IDLE) ? block_idx_x : accepted_block_x;
    wire [15:0] cur_block_y = (rx_state == ST_IDLE) ? block_idx_y : accepted_block_y;
    wire [9:0]  cur_warps_per_block = (rx_state == ST_IDLE) ? warps_per_block : accepted_warps_per_block;
    wire [9:0]  cur_warp_base = (rx_state == ST_IDLE) ? 10'd0 : warp_base;
    wire [15:0] linear_block_id = cur_block_x + (cur_block_y * 16'd65535);

    // Parallel Routing: Map up to NUM_SPS warps to sub-partitions starting at sp_rr_ptr
    wire [9:0]         sp_warp_idx   [0:NUM_SPS-1];
    wire [NUM_SPS-1:0] sp_warp_needed;

    for (genvar s = 0; s < NUM_SPS; s = s + 1) begin : gen_parallel_alloc_calc
        wire [31:0] k_val = (32'(s) >= 32'(sp_rr_ptr)) ?
                            (32'(s) - 32'(sp_rr_ptr)) :
                            (32'(s) + 32'(NUM_SPS) - 32'(sp_rr_ptr));
        assign sp_warp_idx[s]    = cur_warp_base + k_val[9:0];
        assign sp_warp_needed[s] = (sp_warp_idx[s] < cur_warps_per_block);
    end

    // Ready condition: All SPs that need to accept a warp in this slice must be ready
    wire slice_ready   = &(~sp_warp_needed | sp_alloc_ready);
    wire active_commit = (rx_state == ST_IDLE)   ? (block_issue_valid && !block_accepted_reg && slice_ready) :
                         (rx_state == ST_COMMIT) ? slice_ready : 1'b0;

    // Parallel Allocation Ports to all Sub-Partitions
    for (genvar s = 0; s < NUM_SPS; s = s + 1) begin : gen_alloc_ports
        assign alloc[s].valid           = active_commit && sp_warp_needed[s];
        assign alloc[s].block_id        = linear_block_id;
        assign alloc[s].block_idx_x     = cur_block_x;
        assign alloc[s].block_idx_y     = cur_block_y;
        assign alloc[s].thread_id_start = sp_warp_idx[s] * WARP_SIZE;
        assign alloc[s].active_mask     = {{(32-NUM_LANES){1'b0}}, {NUM_LANES{1'b1}}};
    end

    // State machine for CTA Parallel Commit
    always @(posedge clk or negedge sm_rst_n) begin
        if (!sm_rst_n) begin
            rx_state                 <= ST_IDLE;
            block_accepted_reg       <= 1'b0;
            sp_rr_ptr                <= '0;
            warp_base                <= 10'd0;
            accepted_block_x         <= 16'd0;
            accepted_block_y         <= 16'd0;
            accepted_warps_per_block <= 10'd0;
        end else begin
            case (rx_state)
                ST_IDLE: begin
                    block_accepted_reg <= 1'b0;
                    if (block_issue_valid && !block_accepted_reg && slice_ready) begin
                        if (warps_per_block <= 10'(NUM_SPS)) begin
                            // 1-CYCLE PARALLEL COMMIT! All warps absorbed this cycle.
                            block_accepted_reg <= 1'b1;
                            sp_rr_ptr <= SP_PTR_W'((32'(sp_rr_ptr) + 32'(warps_per_block)) % NUM_SPS);
                            rx_state  <= ST_WAIT_DROP;
                        end else begin
                            // Multi-cycle parallel commit (absorbs NUM_SPS warps per cycle)
                            accepted_block_x         <= block_idx_x;
                            accepted_block_y         <= block_idx_y;
                            accepted_warps_per_block <= warps_per_block;
                            warp_base                <= 10'(NUM_SPS);
                            sp_rr_ptr                <= SP_PTR_W'((32'(sp_rr_ptr) + 32'(NUM_SPS)) % NUM_SPS);
                            rx_state                 <= ST_COMMIT;
                        end
                    end
                end

                ST_COMMIT: begin
                    if (slice_ready) begin
                        if (warp_base + 10'(NUM_SPS) >= accepted_warps_per_block) begin
                            // Final slice committed!
                            block_accepted_reg <= 1'b1;
                            sp_rr_ptr <= SP_PTR_W'((32'(sp_rr_ptr) + (32'(accepted_warps_per_block) - 32'(warp_base))) % NUM_SPS);
                            rx_state  <= ST_WAIT_DROP;
                        end else begin
                            warp_base <= warp_base + 10'(NUM_SPS);
                            sp_rr_ptr <= SP_PTR_W'((32'(sp_rr_ptr) + 32'(NUM_SPS)) % NUM_SPS);
                            rx_state  <= ST_COMMIT;
                        end
                    end
                end

                ST_WAIT_DROP: begin
                    block_accepted_reg <= 1'b0;
                    rx_state           <= ST_IDLE;
                end

                default: rx_state <= ST_IDLE;
            endcase
        end
    end

    // Interface signals & debug tracing aliases
    assign block_accepted = block_accepted_reg;

    wire alloc_valid_reg = active_commit;
    wire alloc_ready     = slice_ready;
    wire [SP_PTR_W-1:0] alloc_target_sp = sp_rr_ptr;
    wire [9:0] warp_cnt  = cur_warp_base;

    // Available warp slots reporting to GPC scheduler
    reg [4:0] available_warp_slots_q;
    always @(posedge clk or negedge sm_rst_n) begin
        if (!sm_rst_n) begin
            available_warp_slots_q <= 5'd0;
        end else begin
            if (rx_state == ST_COMMIT || (rx_state == ST_IDLE && block_issue_valid && !block_accepted_reg)) begin
                available_warp_slots_q <= 5'd0;
            end else begin
                available_warp_slots_q <= max_free_slots;
            end
        end
    end
    assign available_warp_slots = available_warp_slots_q;

    // SM Idle Status: receiver is ST_IDLE and all sub-partitions have all warp slots free
    wire [NUM_SPS-1:0] sp_all_free;
    for (genvar s = 0; s < NUM_SPS; s = s + 1) begin : gen_sp_idle_check
        assign sp_all_free[s] = (sp_avail_slots[s] == MAX_WARPS[4:0]);
    end
    assign sm_idle = (rx_state == ST_IDLE) && (&sp_all_free) && !block_issue_valid;

`ifdef ENABLE_GPU_DEBUG
    wire [PERF_COUNT-1:0] sp_perf_events [0:NUM_SPS-1];
    wire [PERF_COUNT-1:0] l1_perf_events;
    reg [31:0] perf_increments_comb [0:PERF_COUNT-1];
    always_comb begin
        for (int c = 0; c < PERF_COUNT; c++) begin
            perf_increments_comb[c] = 32'(l1_perf_events[c]);
            for (int sp = 0; sp < NUM_SPS; sp++)
                perf_increments_comb[c] = perf_increments_comb[c] + 32'(sp_perf_events[sp][c]);
        end
    end

    always @(posedge clk or negedge sm_rst_n) begin
        if (!sm_rst_n) begin
            for (int c = 0; c < PERF_COUNT; c++) perf_increments[c] <= 32'd0;
        end else if (perf_clear) begin
            for (int c = 0; c < PERF_COUNT; c++) perf_increments[c] <= 32'd0;
        end else begin
            for (int c = 0; c < PERF_COUNT; c++) perf_increments[c] <= perf_increments_comb[c];
        end
    end
`endif
    // 2. Sub-Partitions (Compute Blocks)
    wire [NUM_SPS-1:0]        sp_l1_req_valid;
    wire [31:0]               sp_l1_req_addr  [0:NUM_SPS-1];
    wire [DATA_W-1:0]         sp_l1_req_wdata [0:NUM_SPS-1];
    wire [7:0]               sp_l1_req_wstrb [0:NUM_SPS-1];
    wire [NUM_SPS-1:0]        sp_l1_req_we;
    wire [NUM_SPS-1:0]        sp_l1_req_ready;
    wire [NUM_SPS-1:0]        sp_l1_rsp_valid;
    wire [DATA_W-1:0]         sp_l1_rsp_rdata [0:NUM_SPS-1];


    for (genvar m = 0; m < NUM_SPS; m = m + 1) begin : gen_sub_partitions
        sub_partition u_sp (
            .clk           (clk),
            .rst_n         (sm_rst_n),
            
            // I-RAM Loading (Broadcast)
            .iram_we       (iram_we),
            .iram_waddr    (iram_waddr),
            .iram_wdata    (iram_wdata),

            // Warp Allocation
            .alloc         (alloc[m]),
            
            // L1 Request & Response
            .l1_req_valid  (sp_l1_req_valid[m]),
            .l1_req_addr   (sp_l1_req_addr[m]),
            .l1_req_wdata  (sp_l1_req_wdata[m]),
            .l1_req_wstrb  (sp_l1_req_wstrb[m]),
            .l1_req_we     (sp_l1_req_we[m]),
            .l1_req_ready  (sp_l1_req_ready[m]),
            .l1_rsp_valid  (sp_l1_rsp_valid[m]),
            .l1_rsp_rdata  (sp_l1_rsp_rdata[m])
`ifdef ENABLE_GPU_DEBUG
            , .perf_clear(perf_clear), .perf_events(sp_perf_events[m])
`endif
        );
    end


    // 3. M:1 L1 Cache Arbiter & Interconnect
    wire              l1_req_valid_int;
    wire [31:0]       l1_req_addr_int;
    wire [DATA_W-1:0] l1_req_wdata_int;
    wire [7:0]        l1_req_wstrb_int;
    wire              l1_req_we_int;
    wire              l1_req_ready_int;
    wire              l1_rsp_valid_int;
    wire [DATA_W-1:0] l1_rsp_rdata_int;

    generate
        if (NUM_SPS == 1) begin : gen_l1_arb_single
            assign l1_req_valid_int    = sp_l1_req_valid[0];
            assign l1_req_addr_int     = sp_l1_req_addr[0];
            assign l1_req_wdata_int    = sp_l1_req_wdata[0];
            assign l1_req_we_int       = sp_l1_req_we[0];
            assign l1_req_wstrb_int = sp_l1_req_wstrb[0];
            assign sp_l1_req_ready[0]  = l1_req_ready_int;
            assign sp_l1_rsp_valid[0]  = l1_rsp_valid_int;
            assign sp_l1_rsp_rdata[0]  = l1_rsp_rdata_int;
        end else begin : gen_l1_arb_multi
            localparam ARB_IDLE = 1'b0;
            localparam ARB_BUSY = 1'b1;

            reg arb_state;
            reg [$clog2(NUM_SPS)-1:0] current_client;
            reg [$clog2(NUM_SPS)-1:0] rr_ptr;

            // Round-robin selection
            reg [$clog2(NUM_SPS)-1:0] sel_client;
            reg client_found;

            always @(*) begin
                sel_client   = rr_ptr;
                client_found = 1'b0;
                for (int c = 0; c < NUM_SPS; c = c + 1) begin
                    int idx;
                    idx = (32'(rr_ptr) + c) % NUM_SPS;
                    if (!client_found && sp_l1_req_valid[idx]) begin
                        sel_client   = idx[$clog2(NUM_SPS)-1:0];
                        client_found = 1'b1;
                    end
                end
            end

            assign l1_req_valid_int = (arb_state == ARB_IDLE) && client_found;
            assign l1_req_addr_int  = sp_l1_req_addr[sel_client];
            assign l1_req_wdata_int = sp_l1_req_wdata[sel_client];
            assign l1_req_wstrb_int = sp_l1_req_wstrb[sel_client];
            assign l1_req_we_int    = sp_l1_req_we[sel_client];

            for (genvar c = 0; c < NUM_SPS; c = c + 1) begin : gen_sp_ready_rsp
                assign sp_l1_req_ready[c] = (arb_state == ARB_IDLE) && client_found && (sel_client == c) && l1_req_ready_int;
                assign sp_l1_rsp_valid[c] = (arb_state == ARB_BUSY) && (current_client == c) && l1_rsp_valid_int;
                assign sp_l1_rsp_rdata[c] = l1_rsp_rdata_int;
            end

            always @(posedge clk or negedge sm_rst_n) begin
                if (!sm_rst_n) begin
                    arb_state      <= ARB_IDLE;
                    current_client <= '0;
                    rr_ptr         <= '0;
                end else begin
                    case (arb_state)
                        ARB_IDLE: begin
                            if (client_found && l1_req_ready_int) begin
                                current_client <= sel_client;
                                rr_ptr         <= $clog2(NUM_SPS)'((32'(sel_client) + 1) % NUM_SPS);
                                arb_state      <= ARB_BUSY;
                            end
                        end

                        ARB_BUSY: begin
                            if (l1_rsp_valid_int) begin
                                arb_state <= ARB_IDLE;
                            end
                        end
                    endcase
                end
            end
        end
    endgenerate

    // 4. L1 Data Cache (Shared at SM Level)
    l1_cache u_l1_cache (
        .clk (clk),
        .rst_n (sm_rst_n),
        .flush (flush),
        
        .req_valid (l1_req_valid_int),
        .req_addr (l1_req_addr_int),
        .req_wdata (l1_req_wdata_int),
        .req_wstrb (l1_req_wstrb_int),
        .req_we (l1_req_we_int),
        .req_ready (l1_req_ready_int),
        .rsp_valid (l1_rsp_valid_int),
        .rsp_rdata (l1_rsp_rdata_int),
        
        .l2_req_valid (l1_req_valid),
        .l2_req_addr (l1_req_addr),
        .l2_req_wdata (l1_req_wdata),
        .l2_req_wstrb (l1_req_wstrb),
        .l2_req_we (l1_req_we),
        .l2_req_ready (l1_req_ready),
        .l2_rsp_valid (l1_rsp_valid),
        .l2_rsp_rdata (l1_rsp_rdata)
`ifdef ENABLE_GPU_DEBUG
        , .perf_events(l1_perf_events)
`endif
    );

endmodule
