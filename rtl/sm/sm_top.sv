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

    // TBS Dispatch Interface (From GPC)
    input wire block_issue_valid,
    input wire [15:0] block_idx_x,
    input wire [15:0] block_idx_y,
    input wire [9:0] warps_per_block,
    
    output wire block_accepted,
    output wire [4:0] available_warp_slots,

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
);

    // Reset Pipeline (Level 2)
    (* ASYNC_REG = "TRUE" *) reg sm_rst_n_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sm_rst_n_reg <= 1'b0;
        else        sm_rst_n_reg <= 1'b1;
    end
    wire sm_rst_n = sm_rst_n_reg;

    // 1. Thread Block Receiver (Local Scheduler) & Alloc Dispatcher
    warp_alloc_if alloc_rx();
    warp_alloc_if alloc [0:NUM_SPS-1]();

    block_receiver u_block_rx (
        .clk (clk),
        .rst_n (sm_rst_n),
        .block_issue_valid (block_issue_valid),
        .block_idx_x (block_idx_x),
        .block_idx_y (block_idx_y),
        .warps_per_block (warps_per_block),
        .block_accepted (block_accepted),
        .alloc (alloc_rx)
    );

    // Alloc Dispatcher: Routes warp launch to the Sub-Partition with available slots
    generate
        if (NUM_SPS == 1) begin : gen_alloc_single
            assign alloc[0].valid            = alloc_rx.valid;
            assign alloc[0].block_id         = alloc_rx.block_id;
            assign alloc[0].block_idx_x      = alloc_rx.block_idx_x;
            assign alloc[0].block_idx_y      = alloc_rx.block_idx_y;
            assign alloc[0].thread_id_start  = alloc_rx.thread_id_start;
            assign alloc[0].active_mask      = alloc_rx.active_mask;
            assign alloc_rx.ready            = alloc[0].ready;
            assign alloc_rx.available_slots  = alloc[0].available_slots;
            assign available_warp_slots      = alloc[0].available_slots;
        end else begin : gen_alloc_multi
            // Multi-SP Dispatcher: Round-robin or best-effort slot allocation
            reg [$clog2(NUM_SPS)-1:0] alloc_target_sp;
            reg [4:0] max_free_slots;

            always @(*) begin
                alloc_target_sp = '0;
                max_free_slots  = 5'd0;
                for (int s = 0; s < NUM_SPS; s = s + 1) begin
                    if (alloc[s].available_slots > max_free_slots) begin
                        max_free_slots  = alloc[s].available_slots;
                        alloc_target_sp = s[$clog2(NUM_SPS)-1:0];
                    end
                end
            end

            for (genvar s = 0; s < NUM_SPS; s = s + 1) begin : gen_alloc_routing
                assign alloc[s].valid           = alloc_rx.valid && (alloc_target_sp == s);
                assign alloc[s].block_id        = alloc_rx.block_id;
                assign alloc[s].block_idx_x     = alloc_rx.block_idx_x;
                assign alloc[s].block_idx_y     = alloc_rx.block_idx_y;
                assign alloc[s].thread_id_start = alloc_rx.thread_id_start;
                assign alloc[s].active_mask     = alloc_rx.active_mask;
            end

            assign alloc_rx.ready           = alloc[alloc_target_sp].ready;
            assign alloc_rx.available_slots = max_free_slots;
            assign available_warp_slots     = max_free_slots;
        end
    endgenerate

    // 2. Sub-Partitions (Compute Blocks)
    wire [NUM_SPS-1:0]        sp_l1_req_valid;
    wire [31:0]               sp_l1_req_addr  [0:NUM_SPS-1];
    wire [DATA_W-1:0]         sp_l1_req_wdata [0:NUM_SPS-1];
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
            .l1_req_we     (sp_l1_req_we[m]),
            .l1_req_ready  (sp_l1_req_ready[m]),
            .l1_rsp_valid  (sp_l1_rsp_valid[m]),
            .l1_rsp_rdata  (sp_l1_rsp_rdata[m])
        );
    end

    // 3. M:1 L1 Cache Arbiter & Interconnect
    wire              l1_req_valid_int;
    wire [31:0]       l1_req_addr_int;
    wire [DATA_W-1:0] l1_req_wdata_int;
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
                    idx = (rr_ptr + c) % NUM_SPS;
                    if (!client_found && sp_l1_req_valid[idx]) begin
                        sel_client   = idx[$clog2(NUM_SPS)-1:0];
                        client_found = 1'b1;
                    end
                end
            end

            assign l1_req_valid_int = (arb_state == ARB_IDLE) && client_found;
            assign l1_req_addr_int  = sp_l1_req_addr[sel_client];
            assign l1_req_wdata_int = sp_l1_req_wdata[sel_client];
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
                                rr_ptr         <= (sel_client + 1) % NUM_SPS;
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
        
        .req_valid (l1_req_valid_int),
        .req_addr (l1_req_addr_int),
        .req_wdata (l1_req_wdata_int),
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
    );

endmodule
