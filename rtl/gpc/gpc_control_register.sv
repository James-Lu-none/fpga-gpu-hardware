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
    input wire        grid_done_status
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
                    case (s_axi_lite.araddr[7:0])
                        8'h04:   axi_rdata <= {31'd0, grid_done_reg};
                        8'h0C:   axi_rdata <= {16'd0, grid_dim_x};
                        8'h10:   axi_rdata <= {16'd0, grid_dim_y};
                        8'h14:   axi_rdata <= {16'd0, block_dim_x};
                        8'h18:   axi_rdata <= {16'd0, block_dim_y};
                        8'h20:   axi_rdata <= src_addr;
                        8'h24:   axi_rdata <= dst_addr;
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

endmodule
