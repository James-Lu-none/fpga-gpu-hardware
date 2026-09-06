`timescale 1ns / 1ps
// Graphics Processing Cluster (GPC)
// Wraps Multiple Streaming Multiprocessors (SMs) and the GigaThread Engine

import gpu_pkg::*;

module gpc_top (
    input wire clk,
    input wire rst_n,

    // AXI4-Lite Slave Interface (From RISC-V Command Processor)
    axi_lite_if.slave s_axi_lite,

    // 256-bit AXI4-Full Master Interface (To Global Memory Crossbar)
    axi4_if.master m_axi_gmem
);

    // Reset Pipeline (Level 1)
    (* ASYNC_REG = "TRUE" *) reg gpc_rst_n_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) gpc_rst_n_reg <= 1'b0;
        else        gpc_rst_n_reg <= 1'b1;
    end
    wire gpc_rst_n = gpc_rst_n_reg;

    // 1. AXI-Lite Register Decoder & Configuration
    reg [31:0] src_addr;
    reg [31:0] dst_addr;
    reg [15:0] grid_dim_x, grid_dim_y;
    reg [15:0] block_dim_x, block_dim_y;
    reg hw_trigger;
    
    // Broadcast I-RAM Signals to all SMs
    reg iram_we_reg;
    reg [11:0] iram_waddr_reg;
    reg [31:0] iram_wdata_reg;

    assign s_axi_lite.awready = 1'b1;
    assign s_axi_lite.wready = 1'b1;
    assign s_axi_lite.bvalid = s_axi_lite.wvalid && s_axi_lite.awvalid;
    assign s_axi_lite.bresp = 2'b00;

    assign s_axi_lite.arready = 1'b1;
    assign s_axi_lite.rvalid = s_axi_lite.arvalid;
    assign s_axi_lite.rresp = 2'b00;

    wire grid_done_status;
    reg grid_done_reg;

    always @(posedge clk or negedge gpc_rst_n) begin
        if (!gpc_rst_n) begin
            hw_trigger <= 1'b0;
            grid_done_reg <= 1'b0;
            grid_dim_x <= 16'd1;
            grid_dim_y <= 16'd1;
            block_dim_x <= 16'd1;
            block_dim_y <= 16'd1;
            src_addr <= 32'd0;
            dst_addr <= 32'd0;
            
            iram_we_reg <= 1'b0;
            iram_waddr_reg <= 12'd0;
            iram_wdata_reg <= 32'd0;
        end else begin
            iram_we_reg <= 1'b0;
            hw_trigger <= 1'b0; // Auto-clear pulse

            if (s_axi_lite.awvalid && s_axi_lite.wvalid) begin
                if (s_axi_lite.awaddr[12]) begin
                    // 0x1000 ~ 0x1FFF : I-RAM Word Write (Broadcast)
                    iram_we_reg <= 1'b1;
                    iram_waddr_reg <= {2'b00, s_axi_lite.awaddr[11:2]};
                    iram_wdata_reg <= s_axi_lite.wdata;
                end else begin
                    // 0x0000 ~ 0x0FFF : Control Registers
                    case (s_axi_lite.awaddr[7:0])
                        8'h00: hw_trigger <= s_axi_lite.wdata[0];
                        8'h08: grid_done_reg <= 1'b0; // INT_ACK clears done flag
                        8'h0C: grid_dim_x <= s_axi_lite.wdata[15:0];
                        8'h10: grid_dim_y <= s_axi_lite.wdata[15:0];
                        8'h14: block_dim_x <= s_axi_lite.wdata[15:0];
                        8'h18: block_dim_y <= s_axi_lite.wdata[15:0];
                        8'h20: src_addr <= s_axi_lite.wdata;
                        8'h24: dst_addr <= s_axi_lite.wdata;
                    endcase
                end
            end
            
            // Set done flag when grid finishes from TBS
            if (grid_done_status) begin
                grid_done_reg <= 1'b1;
            end
        end
    end

    reg [31:0] rdata_reg;
    // send data when read address change from 
    always @(*) begin
        rdata_reg = 32'd0;
        if (!s_axi_lite.araddr[12]) begin
            case (s_axi_lite.araddr[7:0])
                8'h04: rdata_reg = {31'd0, grid_done_reg};
                8'h0C: rdata_reg = {16'd0, grid_dim_x};
                8'h10: rdata_reg = {16'd0, grid_dim_y};
                8'h14: rdata_reg = {16'd0, block_dim_x};
                8'h18: rdata_reg = {16'd0, block_dim_y};
                8'h20: rdata_reg = src_addr;
                8'h24: rdata_reg = dst_addr;
            endcase
        end
    end
    assign s_axi_lite.rdata = rdata_reg;

    // 2. Dynamic Thread Block Scheduler (TBS / GigaThread Engine)
    wire [(NUM_SMS*5)-1:0] sm_available_warp_slots;
    wire [NUM_SMS-1:0] sm_block_accepted;
    wire [NUM_SMS-1:0] sm_block_issue_valid;
    wire [15:0] sm_block_idx_x;
    wire [15:0] sm_block_idx_y;
    wire [9:0] sm_warps_per_block;

    thread_block_scheduler u_scheduler (
        .clk (clk),
        .rst_n (gpc_rst_n),
        .start (hw_trigger),
        .grid_dim_x (grid_dim_x),
        .grid_dim_y (grid_dim_y),
        .block_dim_x (block_dim_x),
        .block_dim_y (block_dim_y),
        .grid_done (grid_done_status),
        .sm_available_warp_slots(sm_available_warp_slots),
        .sm_block_accepted (sm_block_accepted),
        .sm_block_issue_valid (sm_block_issue_valid),
        .sm_block_idx_x (sm_block_idx_x),
        .sm_block_idx_y (sm_block_idx_y),
        .sm_warps_per_block (sm_warps_per_block)
    );

    // 3. SM Array & AXI Arbiter (NUM_SMS = 2)
    // L1 to L2 Cache Interfaces
    wire sm0_l1_req_valid;
    wire [31:0] sm0_l1_req_addr;
    wire [255:0]sm0_l1_req_wdata;
    wire [31:0] sm0_l1_req_wstrb;
    wire sm0_l1_req_we;
    wire sm0_l1_req_ready;
    wire sm0_l1_rsp_valid;
    wire [255:0]sm0_l1_rsp_rdata;

    wire sm1_l1_req_valid;
    wire [31:0] sm1_l1_req_addr;
    wire [255:0]sm1_l1_req_wdata;
    wire [31:0] sm1_l1_req_wstrb;
    wire sm1_l1_req_we;
    wire sm1_l1_req_ready;
    wire sm1_l1_rsp_valid;
    wire [255:0]sm1_rsp_rdata;

    wire [4:0] sm0_slots;

    wire [4:0] sm1_slots = 5'd0;

    // assign sm_available_warp_slots = {sm1_slots, sm0_slots};
    assign sm_available_warp_slots = {sm1_slots};

    // SM 0
    streaming_multiprocessor u_sm_0 (
        .clk (clk),
        .rst_n (gpc_rst_n),
        .block_issue_valid (sm_block_issue_valid[0]),
        .block_idx_x (sm_block_idx_x),
        .block_idx_y (sm_block_idx_y),
        .warps_per_block (sm_warps_per_block),
        .block_accepted (sm_block_accepted[0]),
        .available_warp_slots (sm0_slots),
        .dma_src_addr (src_addr),
        .dma_dst_addr (dst_addr),
        .iram_we (iram_we_reg),
        .iram_waddr (iram_waddr_reg),
        .iram_wdata (iram_wdata_reg),
        .l1_req_valid (sm0_l1_req_valid),
        .l1_req_addr (sm0_l1_req_addr),
        .l1_req_wdata (sm0_l1_req_wdata),
        .l1_req_wstrb (sm0_l1_req_wstrb),
        .l1_req_we (sm0_l1_req_we),
        .l1_req_ready (sm0_l1_req_ready),
        .l1_rsp_valid (sm0_l1_rsp_valid),
        .l1_rsp_rdata (sm0_l1_rsp_rdata)
    );

    // // SM 1
    // streaming_multiprocessor u_sm_1 (
    //     .clk (clk),
    //     .rst_n (rst_n),
    //     .block_issue_valid (sm_block_issue_valid[1]),
    //     .block_idx_x (sm_block_idx_x),
    //     .block_idx_y (sm_block_idx_y),
    //     .warps_per_block (sm_warps_per_block),
    //     .block_accepted (sm_block_accepted[1]),
    //     .available_warp_slots (sm1_slots),
    //     .dma_src_addr (src_addr),
    //     .dma_dst_addr (dst_addr),
    //     .iram_we (iram_we_reg),
    //     .iram_waddr (iram_waddr_reg),
    //     .iram_wdata (iram_wdata_reg),
    //     .l1_req_valid (sm1_l1_req_valid),
    //     .l1_req_addr (sm1_l1_req_addr),
    //     .l1_req_wdata (sm1_l1_req_wdata),
    //     .l1_req_wstrb (sm1_l1_req_wstrb),
    //     .l1_req_we (sm1_l1_req_we),
    //     .l1_req_ready (sm1_l1_req_ready),
    //     .l1_rsp_valid (sm1_l1_rsp_valid),
    //     .l1_rsp_rdata (sm1_rsp_rdata)
    // );

    // Shared L2 Cache & AXI4 Master
    l2_cache u_l2_cache (
        .clk (clk),
        .rst_n (gpc_rst_n),
        
        .sm0_req_valid (sm0_l1_req_valid),
        .sm0_req_addr (sm0_l1_req_addr),
        .sm0_req_wdata (sm0_l1_req_wdata),
        .sm0_req_wstrb (sm0_l1_req_wstrb),
        .sm0_req_we (sm0_l1_req_we),
        .sm0_req_ready (sm0_l1_req_ready),
        .sm0_rsp_valid (sm0_l1_rsp_valid),
        .sm0_rsp_rdata (sm0_l1_rsp_rdata),
        
        .sm1_req_valid (sm1_l1_req_valid),
        .sm1_req_addr (sm1_l1_req_addr),
        .sm1_req_wdata (sm1_l1_req_wdata),
        .sm1_req_wstrb (sm1_l1_req_wstrb),
        .sm1_req_we (sm1_l1_req_we),
        .sm1_req_ready (sm1_l1_req_ready),
        .sm1_rsp_valid (sm1_l1_rsp_valid),
        .sm1_rsp_rdata (sm1_rsp_rdata),
        
        .m_axi_awvalid (m_axi_gmem.awvalid),
        .m_axi_awaddr (m_axi_gmem.awaddr),
        .m_axi_awlen (m_axi_gmem.awlen),
        .m_axi_awsize (m_axi_gmem.awsize),
        .m_axi_awburst (m_axi_gmem.awburst),
        .m_axi_awready (m_axi_gmem.awready),
        
        .m_axi_wvalid (m_axi_gmem.wvalid),
        .m_axi_wdata (m_axi_gmem.wdata),
        .m_axi_wstrb (m_axi_gmem.wstrb),
        .m_axi_wlast (m_axi_gmem.wlast),
        .m_axi_wready (m_axi_gmem.wready),
        
        .m_axi_bvalid (m_axi_gmem.bvalid),
        .m_axi_bready (m_axi_gmem.bready),
        
        .m_axi_arvalid (m_axi_gmem.arvalid),
        .m_axi_araddr (m_axi_gmem.araddr),
        .m_axi_arlen (m_axi_gmem.arlen),
        .m_axi_arsize (m_axi_gmem.arsize),
        .m_axi_arburst (m_axi_gmem.arburst),
        .m_axi_arready (m_axi_gmem.arready),
        
        .m_axi_rvalid (m_axi_gmem.rvalid),
        .m_axi_rdata (m_axi_gmem.rdata),
        .m_axi_rlast (m_axi_gmem.rlast),
        .m_axi_rready (m_axi_gmem.rready)
    );

endmodule
