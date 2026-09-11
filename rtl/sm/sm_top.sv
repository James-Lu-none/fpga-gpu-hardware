`timescale 1ns / 1ps

// GPU Streaming Multiprocessor (SM)
// Receives dynamic Thread Block assignments from the GigaThread Engine (TBS).

module streaming_multiprocessor (
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

    // 1. Thread Block Receiver (Local Scheduler)
    warp_alloc_if alloc();

    block_receiver u_block_rx (
        .clk (clk),
        .rst_n (sm_rst_n),
        .block_issue_valid (block_issue_valid),
        .block_idx_x (block_idx_x),
        .block_idx_y (block_idx_y),
        .warps_per_block (warps_per_block),
        .block_accepted (block_accepted),
        
        .alloc (alloc)
    );
    
    assign available_warp_slots = alloc.available_slots;

    // 2. Sub-Core (Processing Block)
    // Internal wires for LSU to L1 Cache communication
    wire l1_req_valid_int;
    wire [31:0] l1_req_addr_int;
    wire [63:0] l1_req_wdata_int;
    wire l1_req_we_int;
    wire l1_req_ready_int;
    wire l1_rsp_valid_int;
    wire [63:0] l1_rsp_rdata_int;

    sub_partition u_sp_0 (
        .clk (clk),
        .rst_n (sm_rst_n),
        
        // I-RAM Loading
        .iram_we (iram_we),
        .iram_waddr (iram_waddr),
        .iram_wdata (iram_wdata),

        // Warp Allocation
        .alloc (alloc),
        
        .l1_req_valid (l1_req_valid_int),
        .l1_req_addr (l1_req_addr_int),
        .l1_req_wdata (l1_req_wdata_int),
        .l1_req_we (l1_req_we_int),
        .l1_req_ready (l1_req_ready_int),
        .l1_rsp_valid (l1_rsp_valid_int),
        .l1_rsp_rdata (l1_rsp_rdata_int)
    );

    // 3. L1 Data Cache (Shared at SM Level)
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
