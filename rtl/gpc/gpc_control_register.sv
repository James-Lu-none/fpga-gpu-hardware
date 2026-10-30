`timescale 1ns / 1ps

// Decodes Command Processor (PicoRV32) control registers (0x0000 ~ 0x0FFF)
// and broadcasts I-RAM writes (0x1000 ~ 0x1FFF) to all SMs.

module gpc_control_register (
    input wire        clk,
    input wire        rst_n,

    // AXI4-Lite Slave Interface (From RISC-V Crossbar Port M02)
    axi_lite_if.slave s_axi_lite,

    // Control Registers & Launch Pulse
    output reg        hw_trigger,
    output reg        cache_flush,
    output reg [15:0] grid_dim_x,
    output reg [15:0] grid_dim_y,
    output reg [15:0] block_dim_x,
    output reg [15:0] block_dim_y,
    output reg [31:0] src_addr,
    output reg [31:0] dst_addr,

    // Broadcast I-RAM Write Interface (0x1000 ~ 0x1FFF)
    output reg        iram_we,
    output reg [11:0] iram_waddr,
    output reg [31:0] iram_wdata,

    // Status input from Thread Block Scheduler
    input wire        grid_done_status,

    // Level interrupt for PicoRV32. It remains asserted until INT_ACK (0x08)
    // clears the completion status.
    output wire       completion_irq
`ifdef ENABLE_GPU_DEBUG
    , input wire [31:0] perf_increments [0:gpu_pkg::PERF_COUNT-1],
    input wire debug_ar_fire, debug_r_fire, debug_aw_fire, debug_w_fire,
    input wire [31:0] debug_ar_addr, debug_aw_addr, debug_wstrb,
    input wire [255:0] debug_rdata,
    input wire [63:0] debug_wdata,
    output wire perf_clear
`endif
);

    // AXI4-Lite Registered Outputs
    reg        axi_awready;
    reg        axi_wready;
    reg [1:0]  axi_bresp;
    reg        axi_bvalid;
    reg        axi_arready;
    reg [31:0] axi_rdata;
    reg [1:0]  axi_rresp;
    reg        axi_rvalid;

    assign s_axi_lite.awready = axi_awready;
    assign s_axi_lite.wready  = axi_wready;
    assign s_axi_lite.bresp   = axi_bresp;
    assign s_axi_lite.bvalid  = axi_bvalid;
    assign s_axi_lite.arready = axi_arready;
    assign s_axi_lite.rdata   = axi_rdata;
    assign s_axi_lite.rresp   = axi_rresp;
    assign s_axi_lite.rvalid  = axi_rvalid;

    
    // Decoupled Write Channel Handshake & Register Update
    reg        aw_done;
    reg        w_done;
    reg [31:0] latched_awaddr;
    reg [31:0] latched_wdata;
    reg [3:0]  latched_wstrb;

    reg        grid_done_reg;

    assign completion_irq = grid_done_reg;

    wire write_addr_ready = s_axi_lite.awvalid && (!aw_done || axi_awready);
    wire write_data_ready = s_axi_lite.wvalid && (!w_done || axi_wready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_awready   <= 1'b0;
            axi_wready    <= 1'b0;
            axi_bvalid    <= 1'b0;
            axi_bresp     <= 2'b00;

            aw_done       <= 1'b0;
            w_done        <= 1'b0;
            latched_awaddr <= 32'd0;
            latched_wdata  <= 32'd0;
            latched_wstrb  <= 4'd0;

            hw_trigger    <= 1'b0;
            cache_flush   <= 1'b0;
            grid_done_reg <= 1'b0;
            grid_dim_x    <= 16'd1;
            grid_dim_y    <= 16'd1;
            block_dim_x   <= 16'd1;
            block_dim_y   <= 16'd1;
            src_addr      <= 32'd0;
            dst_addr      <= 32'd0;

            iram_we       <= 1'b0;
            iram_waddr    <= 12'd0;
            iram_wdata    <= 32'd0;
        end else begin
            // 1-cycle auto-clearing pulses
            hw_trigger  <= 1'b0;
            cache_flush <= 1'b0;
            iram_we     <= 1'b0;

            // Hardware completion flag from scheduler
            if (grid_done_status) begin
                grid_done_reg <= 1'b1;
            end

            // 1. Latch Write Address
            if (!aw_done) begin
                if (s_axi_lite.awvalid && !axi_awready) begin
                    axi_awready    <= 1'b1;
                    latched_awaddr <= s_axi_lite.awaddr;
                    aw_done        <= 1'b1;
                end
            end else if (axi_awready) begin
                axi_awready <= 1'b0;
            end

            // 2. Latch Write Data
            if (!w_done) begin
                if (s_axi_lite.wvalid && !axi_wready) begin
                    axi_wready    <= 1'b1;
                    latched_wdata <= s_axi_lite.wdata;
                    latched_wstrb <= s_axi_lite.wstrb;
                    w_done        <= 1'b1;
                end
            end else if (axi_wready) begin
                axi_wready <= 1'b0;
            end

            // 3. Both Address & Data Latched -> Execute Write and Respond
            if (aw_done && w_done && !axi_bvalid) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b00; // OKAY
                aw_done    <= 1'b0;
                w_done     <= 1'b0;

                if (latched_awaddr[12]) begin
                    // 0x1000 ~ 0x1FFF: I-RAM Word Write (Broadcast)
                    iram_we    <= 1'b1;
                    iram_waddr <= {2'b00, latched_awaddr[11:2]};
                    iram_wdata <= latched_wdata;
                end else begin
                    // 0x0000 ~ 0x0FFF: Control Registers
                    case (latched_awaddr[7:0])
                        8'h00: begin
                            hw_trigger  <= latched_wdata[0];
                            // Auto-flush on kernel launch (bit 0) or explicit flush bit (bit 1)
                            cache_flush <= latched_wdata[0] | latched_wdata[1];
                        end
                        8'h08: grid_done_reg <= 1'b0; // INT_ACK clears done flag
                        8'h0C: grid_dim_x    <= latched_wdata[15:0];
                        8'h10: grid_dim_y    <= latched_wdata[15:0];
                        8'h14: block_dim_x   <= latched_wdata[15:0];
                        8'h18: block_dim_y   <= latched_wdata[15:0];
                        8'h20: src_addr      <= latched_wdata;
                        8'h24: dst_addr      <= latched_wdata;
                        8'h28: cache_flush   <= 1'b1; // Explicit cache invalidate register
                        default: ;
                    endcase
                end
            end

            // 4. Complete Write Response Handshake
            if (axi_bvalid && s_axi_lite.bready) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    
    // Registered Read Channel Handshake
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 2'b00;
            axi_rdata   <= 32'd0;
        end else begin
            // 1. Accept Read Address
            if (!axi_arready && s_axi_lite.arvalid && (!axi_rvalid || s_axi_lite.rready)) begin
                axi_arready <= 1'b1;
            end else begin
                axi_arready <= 1'b0;
            end

            // 2. Sample Address, Latch Read Data, and Assert RVALID (1-Cycle Latency)
            if (axi_arready && s_axi_lite.arvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b00; // OKAY

                if (!s_axi_lite.araddr[12]) begin
`ifdef ENABLE_GPU_DEBUG
                    if (s_axi_lite.araddr[11:0] >= 12'h030 &&
                        s_axi_lite.araddr[11:0] < 12'h030 + gpu_pkg::PERF_COUNT*4 && s_axi_lite.araddr[1:0] == 0)
                        axi_rdata <= perf_counters[$clog2(gpu_pkg::PERF_COUNT)'((s_axi_lite.araddr[11:0] - 12'h030) >> 2)];
                    else if (s_axi_lite.araddr[11:0] >= 12'h088 &&
                             s_axi_lite.araddr[11:0] < 12'h0A8 && s_axi_lite.araddr[1:0] == 0)
                        axi_rdata <= first_rdata[8'(s_axi_lite.araddr[11:0] - 12'h088)*8 +: 32];
                    else
`endif
                    case (s_axi_lite.araddr[7:0])
                        8'h04:   axi_rdata <= {31'd0, grid_done_reg};
                        8'h0C:   axi_rdata <= {16'd0, grid_dim_x};
                        8'h10:   axi_rdata <= {16'd0, grid_dim_y};
                        8'h14:   axi_rdata <= {16'd0, block_dim_x};
                        8'h18:   axi_rdata <= {16'd0, block_dim_y};
                        8'h20:   axi_rdata <= src_addr;
                        8'h24:   axi_rdata <= dst_addr;
`ifdef ENABLE_GPU_DEBUG
                        8'h80:   axi_rdata <= {28'd0, first_axi_seen};
                        8'h84:   axi_rdata <= first_araddr;
                        8'hA8:   axi_rdata <= first_awaddr;
                        8'hAC:   axi_rdata <= first_wstrb;
                        8'hB0:   axi_rdata <= first_wdata[31:0];
                        8'hB4:   axi_rdata <= first_wdata[63:32];
`endif
                        default: axi_rdata <= 32'd0;
                    endcase
                end else begin
                    axi_rdata <= 32'd0;
                end
            end else if (axi_rvalid && s_axi_lite.rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

`ifdef ENABLE_GPU_DEBUG
    // First accepted DDR transaction of each launch. AW and W are independent.
    reg [3:0] first_axi_seen;
    reg [31:0] first_araddr, first_awaddr, first_wstrb;
    reg [255:0] first_rdata;
    reg [63:0] first_wdata;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) first_axi_seen <= 0;
        else if (perf_clear) first_axi_seen <= 0;
        else begin
            if (debug_ar_fire) first_axi_seen[0] <= 1;
            if (debug_r_fire) first_axi_seen[1] <= 1;
            if (debug_aw_fire) first_axi_seen[2] <= 1;
            if (debug_w_fire) first_axi_seen[3] <= 1;
        end
    end
    // Payload is valid only when its corresponding seen bit is set.
    always @(posedge clk) begin
        if (debug_ar_fire && !first_axi_seen[0]) first_araddr <= debug_ar_addr;
        if (debug_r_fire && !first_axi_seen[1]) first_rdata <= debug_rdata;
        if (debug_aw_fire && !first_axi_seen[2]) first_awaddr <= debug_aw_addr;
        if (debug_w_fire && !first_axi_seen[3]) begin
            first_wstrb <= debug_wstrb;
            first_wdata <= debug_wdata;
        end
    end
    reg [31:0] perf_counters [0:gpu_pkg::PERF_COUNT-1];
    reg perf_running;
    wire manual_clear = aw_done && w_done && !axi_bvalid &&
        !latched_awaddr[12] && latched_awaddr[11:0] == 12'h02c && latched_wstrb[0] && latched_wdata[0];
    assign perf_clear = hw_trigger || manual_clear;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_running <= 0;
            for (int c = 0; c < gpu_pkg::PERF_COUNT; c++) perf_counters[c] <= 0;
        end else begin
            if (hw_trigger) perf_running <= 1;
            else if (grid_done_status) perf_running <= 0;
            if (perf_clear) begin
                for (int c = 0; c < gpu_pkg::PERF_COUNT; c++) perf_counters[c] <= 0;
            end else if (perf_running) begin
                for (int c = 0; c < gpu_pkg::PERF_COUNT; c++) begin
                    if (c == gpu_pkg::PERF_CYCLE) perf_counters[c] <= perf_counters[c] + 1;
                    else perf_counters[c] <= perf_counters[c] + perf_increments[c];
                end
            end
        end
    end
`endif
endmodule
