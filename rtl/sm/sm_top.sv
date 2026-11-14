`timescale 1ns / 1ps

// GPU Streaming Multiprocessor (SM)
// Receives dynamic Thread Block assignments from the GigaThread Engine (TBS).
// Encapsulates M Sub-Partitions, local Thread Block Receiver, and Shared L1 Cache.

`include "gpu_defines.vh"

module streaming_multiprocessor (
    input wire clk,
    input wire rst_n,
    input wire flush,

    // TBS Dispatch Interface (From GPC)
    input wire block_issue_valid,
    input wire [15:0] block_idx_x,
    input wire [15:0] block_idx_y,
    input wire [9:0] warps_per_block,
    input wire [15:0] threads_per_block,
    input wire [15:0] block_dim_x,
    
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
    output reg [31:0] perf_increments [0:`PERF_COUNT-1]
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

    localparam SP_PTR_W = (`NUM_SPS > 1) ? $clog2(`NUM_SPS) : 1;
    reg [SP_PTR_W-1:0] sp_rr_ptr;

    warp_alloc_if alloc [0:`NUM_SPS-1]();

    // Unpack interface signals to regular logic arrays
    // since interface array is not allow to use runtime value as index
    wire [4:0]           sp_avail_slots [0:`NUM_SPS-1];
    wire [`NUM_SPS-1:0]  sp_alloc_ready;

    for (genvar s = 0; s < `NUM_SPS; s = s + 1) begin : gen_alloc_unpack
        assign sp_avail_slots[s] = alloc[s].available_slots;
        assign sp_alloc_ready[s] = alloc[s].ready;
    end

    // Compute total available warp slots across all sub-partitions
    wire [4:0] max_free_slots;
    generate
        if (`NUM_SPS == 1) begin : gen_alloc_cap_single
            assign max_free_slots = sp_avail_slots[0];
        end else begin : gen_alloc_cap_multi
            reg [5:0] total_free_slots_comb;
            always @(*) begin
                total_free_slots_comb = 6'd0;
                for (int s = 0; s < `NUM_SPS; s = s + 1) begin
                    total_free_slots_comb = total_free_slots_comb + 6'(sp_avail_slots[s]);
                end
            end
            assign max_free_slots = (total_free_slots_comb > 6'd31) ? 5'd31 : total_free_slots_comb[4:0];
        end
    endgenerate

    // Current block coordinates and dimensions (pass-through in IDLE for 1-cycle commit)
    reg [15:0] accepted_threads_per_block;
    wire [15:0] cur_block_x = (rx_state == ST_IDLE) ? block_idx_x : accepted_block_x;
    wire [15:0] cur_block_y = (rx_state == ST_IDLE) ? block_idx_y : accepted_block_y;
    wire [9:0]  cur_warps_per_block = (rx_state == ST_IDLE) ? warps_per_block : accepted_warps_per_block;
    wire [15:0] cur_threads_per_block = (rx_state == ST_IDLE) ? threads_per_block : accepted_threads_per_block;
    wire [15:0] eff_threads_per_block = (cur_threads_per_block != 16'd0) ? cur_threads_per_block :
                                        (16'(cur_warps_per_block) * 16'(`WARP_SIZE));
    wire [9:0]  cur_warp_base = (rx_state == ST_IDLE) ? 10'd0 : warp_base;
    wire [15:0] linear_block_id = cur_block_x + (cur_block_y * 16'd65535);

    // Parallel Routing: Map up to NUM_SPS warps to sub-partitions starting at sp_rr_ptr
    wire [9:0]           sp_warp_idx   [0:`NUM_SPS-1];
    wire [`NUM_SPS-1:0]  sp_warp_needed;

    for (genvar s = 0; s < `NUM_SPS; s = s + 1) begin : gen_parallel_alloc_calc
        if (`NUM_SPS == 1) begin : gen_single_sp
            assign sp_warp_idx[s]    = cur_warp_base;
            assign sp_warp_needed[s] = (cur_warp_base < cur_warps_per_block);
        end else begin : gen_multi_sp
            wire [SP_PTR_W-1:0] k_val = SP_PTR_W'(s) - sp_rr_ptr;
            assign sp_warp_idx[s]    = {cur_warp_base[9:SP_PTR_W], k_val};
            assign sp_warp_needed[s] = (sp_warp_idx[s] < cur_warps_per_block);
        end
    end

    // Ready condition: All SPs that need to accept a warp in this slice must be ready
    wire slice_ready   = &(~sp_warp_needed | sp_alloc_ready);
    wire active_commit = (rx_state == ST_IDLE)   ? (block_issue_valid && !block_accepted_reg && slice_ready) :
                         (rx_state == ST_COMMIT) ? slice_ready : 1'b0;

    // Parallel Allocation Ports to all Sub-Partitions
    for (genvar s = 0; s < `NUM_SPS; s = s + 1) begin : gen_alloc_ports
        wire [15:0] warp_start_thread = sp_warp_idx[s] * 16'(`WARP_SIZE);
        wire [15:0] remaining_threads = (eff_threads_per_block > warp_start_thread) ?
                                        (eff_threads_per_block - warp_start_thread) : 16'd0;
        wire [5:0] warp_active_lanes = (remaining_threads >= 16'(`WARP_SIZE)) ? 6'(`WARP_SIZE) : remaining_threads[5:0];
        wire [31:0] warp_active_mask = (warp_active_lanes == 6'd0) ? 32'd0 :
                                       (warp_active_lanes >= 6'd32) ? 32'hFFFFFFFF :
                                       ((32'd1 << warp_active_lanes) - 32'd1);

        assign alloc[s].valid           = active_commit && sp_warp_needed[s];
        assign alloc[s].block_id        = linear_block_id;
        assign alloc[s].block_idx_x     = cur_block_x;
        assign alloc[s].block_idx_y     = cur_block_y;
        assign alloc[s].thread_id_start = warp_start_thread;
        assign alloc[s].active_mask     = warp_active_mask;
    end

    // State machine for CTA Parallel Commit
    always @(posedge clk or negedge sm_rst_n) begin
        if (!sm_rst_n) begin
            rx_state                   <= ST_IDLE;
            block_accepted_reg         <= 1'b0;
            sp_rr_ptr                  <= '0;
            warp_base                  <= 10'd0;
            accepted_block_x           <= 16'd0;
            accepted_block_y           <= 16'd0;
            accepted_warps_per_block   <= 10'd0;
            accepted_threads_per_block <= 16'd0;
        end else begin
            case (rx_state)
                ST_IDLE: begin
                    block_accepted_reg <= 1'b0;
                    if (block_issue_valid && !block_accepted_reg && slice_ready) begin
                        if (warps_per_block <= 10'(`NUM_SPS)) begin
                            // 1-CYCLE PARALLEL COMMIT! All warps absorbed this cycle.
                            block_accepted_reg <= 1'b1;
                            sp_rr_ptr <= sp_rr_ptr + warps_per_block[SP_PTR_W-1:0];
                            rx_state  <= ST_WAIT_DROP;
                        end else begin
                            // Multi-cycle parallel commit (absorbs NUM_SPS warps per cycle)
                            accepted_block_x           <= block_idx_x;
                            accepted_block_y           <= block_idx_y;
                            accepted_warps_per_block   <= warps_per_block;
                            accepted_threads_per_block <= threads_per_block;
                            warp_base                  <= 10'(`NUM_SPS);
                            rx_state                   <= ST_COMMIT;
                        end
                    end
                end

                ST_COMMIT: begin
                    if (slice_ready) begin
                        if (warp_base + 10'(`NUM_SPS) >= accepted_warps_per_block) begin
                            // Final slice committed!
                            block_accepted_reg <= 1'b1;
                            sp_rr_ptr <= sp_rr_ptr + accepted_warps_per_block[SP_PTR_W-1:0];
                            rx_state  <= ST_WAIT_DROP;
                        end else begin
                            warp_base <= warp_base + 10'(`NUM_SPS);
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
    wire [`NUM_SPS-1:0] sp_all_free;
    for (genvar s = 0; s < `NUM_SPS; s = s + 1) begin : gen_sp_idle_check
        assign sp_all_free[s] = (sp_avail_slots[s] == 5'(`MAX_WARPS));
    end
    assign sm_idle = (rx_state == ST_IDLE) && (&sp_all_free) && !block_issue_valid;

`ifdef ENABLE_GPU_DEBUG
    wire [`PERF_COUNT-1:0] sp_perf_events [0:`NUM_SPS-1];
    wire [`PERF_COUNT-1:0] l1_perf_events;
    wire [`PERF_COUNT-1:0] coalesce_perf_events;
    reg [31:0] perf_increments_comb [0:`PERF_COUNT-1];
    always_comb begin
        for (int c = 0; c < `PERF_COUNT; c++) begin
            perf_increments_comb[c] = 32'(l1_perf_events[c]) + 32'(coalesce_perf_events[c]);
            for (int sp = 0; sp < `NUM_SPS; sp++)
                perf_increments_comb[c] = perf_increments_comb[c] + 32'(sp_perf_events[sp][c]);
        end
    end

    always @(posedge clk or negedge sm_rst_n) begin
        if (!sm_rst_n) begin
            for (int c = 0; c < `PERF_COUNT; c++) perf_increments[c] <= 32'd0;
        end else if (perf_clear) begin
            for (int c = 0; c < `PERF_COUNT; c++) perf_increments[c] <= 32'd0;
        end else begin
            for (int c = 0; c < `PERF_COUNT; c++) perf_increments[c] <= perf_increments_comb[c];
        end
    end
`endif
    // 2. Sub-Partitions (Compute Blocks)
    wire [`NUM_SPS-1:0]             sp_mem_req_valid;
    wire [`NUM_SPS-1:0]             sp_mem_req_is_load;
    wire [$clog2(`MAX_WARPS)-1:0]   sp_mem_req_warp_id [0:`NUM_SPS-1];
    wire [4:0]                      sp_mem_req_rd      [0:`NUM_SPS-1];
    wire [11:0]                     sp_mem_req_pc      [0:`NUM_SPS-1];
    wire [`NUM_LANES-1:0]           sp_mem_req_mask    [0:`NUM_SPS-1];
    wire [`WARP_DATA_W-1:0]         sp_mem_req_addr    [0:`NUM_SPS-1];
    wire [`WARP_DATA_W-1:0]         sp_mem_req_wdata   [0:`NUM_SPS-1];
    wire [`NUM_SPS-1:0]             sp_mem_req_ready;

    wire [`NUM_SPS-1:0]             sp_mem_rsp_valid;
    wire [$clog2(`MAX_WARPS)-1:0]   sp_mem_rsp_warp_id [0:`NUM_SPS-1];
    wire [4:0]                      sp_mem_rsp_rd      [0:`NUM_SPS-1];
    wire [11:0]                     sp_mem_rsp_pc      [0:`NUM_SPS-1];
    wire [`NUM_LANES-1:0]           sp_mem_rsp_mask    [0:`NUM_SPS-1];
    wire [`NUM_SPS-1:0]             sp_mem_rsp_is_load;
    wire [`WARP_DATA_W-1:0]         sp_mem_rsp_rdata   [0:`NUM_SPS-1];

    for (genvar m = 0; m < `NUM_SPS; m = m + 1) begin : gen_sub_partitions
        sub_partition u_sp (
            .clk           (clk),
            .rst_n         (sm_rst_n),
            
            // I-RAM Loading (Broadcast)
            .iram_we       (iram_we),
            .iram_waddr    (iram_waddr),
            .iram_wdata    (iram_wdata),

            // Warp Allocation
            .alloc         (alloc[m]),
            .block_dim_x   (block_dim_x),
            
            // Memory Interface to Dynamic Coalescing Engine
            .mem_req_valid  (sp_mem_req_valid[m]),
            .mem_req_is_load(sp_mem_req_is_load[m]),
            .mem_req_warp_id(sp_mem_req_warp_id[m]),
            .mem_req_rd     (sp_mem_req_rd[m]),
            .mem_req_pc     (sp_mem_req_pc[m]),
            .mem_req_mask   (sp_mem_req_mask[m]),
            .mem_req_addr   (sp_mem_req_addr[m]),
            .mem_req_wdata  (sp_mem_req_wdata[m]),
            .mem_req_ready  (sp_mem_req_ready[m]),

            .mem_rsp_valid  (sp_mem_rsp_valid[m]),
            .mem_rsp_warp_id(sp_mem_rsp_warp_id[m]),
            .mem_rsp_rd     (sp_mem_rsp_rd[m]),
            .mem_rsp_pc     (sp_mem_rsp_pc[m]),
            .mem_rsp_mask   (sp_mem_rsp_mask[m]),
            .mem_rsp_is_load(sp_mem_rsp_is_load[m]),
            .mem_rsp_rdata  (sp_mem_rsp_rdata[m])
`ifdef ENABLE_GPU_DEBUG
            , .perf_clear(perf_clear), .perf_events(sp_perf_events[m])
`endif
        );
    end

    // 3. SM-Level Dynamic Coalescing Engine
    wire                     l1_req_valid_int;
    wire [31:0]              l1_req_addr_int;
    wire [`DATA_W_L1-1:0]    l1_req_wdata_int;
    wire [`STRB_W_L1-1:0]    l1_req_wstrb_int;
    wire                     l1_req_we_int;
    wire                     l1_req_ready_int;
    wire                     l1_rsp_valid_int;
    wire [`DATA_W_L1-1:0]    l1_rsp_rdata_int;

    dynamic_coalescing_engine u_coalescing_engine (
        .clk             (clk),
        .rst_n           (sm_rst_n),
        
        .sp_req_valid    (sp_mem_req_valid),
        .sp_req_is_load  (sp_mem_req_is_load),
        .sp_req_warp_id  (sp_mem_req_warp_id),
        .sp_req_rd       (sp_mem_req_rd),
        .sp_req_pc       (sp_mem_req_pc),
        .sp_req_mask     (sp_mem_req_mask),
        .sp_req_addr     (sp_mem_req_addr),
        .sp_req_wdata    (sp_mem_req_wdata),
        .sp_req_ready    (sp_mem_req_ready),

        .sp_rsp_valid    (sp_mem_rsp_valid),
        .sp_rsp_warp_id  (sp_mem_rsp_warp_id),
        .sp_rsp_rd       (sp_mem_rsp_rd),
        .sp_rsp_pc       (sp_mem_rsp_pc),
        .sp_rsp_mask     (sp_mem_rsp_mask),
        .sp_rsp_is_load  (sp_mem_rsp_is_load),
        .sp_rsp_rdata    (sp_mem_rsp_rdata),

        .l1_req_valid    (l1_req_valid_int),
        .l1_req_addr     (l1_req_addr_int),
        .l1_req_wdata    (l1_req_wdata_int),
        .l1_req_wstrb    (l1_req_wstrb_int),
        .l1_req_we       (l1_req_we_int),
        .l1_req_ready    (l1_req_ready_int),
        .l1_rsp_valid    (l1_rsp_valid_int),
        .l1_rsp_rdata    (l1_rsp_rdata_int)
`ifdef ENABLE_GPU_DEBUG
        , .perf_events   (coalesce_perf_events)
`endif
    );

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
