`timescale 1ns / 1ps

import gpu_pkg::*;

// Decodes Host (PCIe BAR0) and PicoRV32 Control & Status Registers (0x0002_0000 ~ 0x0002_0FFF)
// - 0x00: Host Doorbell / CPU IRQ (Bit 0: IRQ Assert)
// - 0x04: PicoRV32 CPU Soft-Reset (Bit 0: Active-Low Reset - 0: In Reset, 1: Running)
// - 0x08: Hardware Major Version (Read-Only)
// - 0x0C: Hardware Minor Version (Read-Only)

module rv_control_register (
    input wire        clk,
    input wire        rst_n,

    // AXI4-Lite Slave Interface (From Crossbar Port M01)
    axi_lite_if.slave s_axi_lite,

    // Control Outputs
    output reg        irq_out,
    output reg        cpu_soft_rst_n_out,

    // One-cycle completion event from firmware. gpu_top holds the resulting
    // XDMA user IRQ request until the XDMA block acknowledges it.
    output reg        host_irq_notify
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

    // Decoupled Write Channel Handshake
    reg        aw_done;
    reg        w_done;
    reg [31:0] latched_awaddr;
    reg [31:0] latched_wdata;
    reg [3:0]  latched_wstrb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_awready        <= 1'b0;
            axi_wready         <= 1'b0;
            axi_bvalid         <= 1'b0;
            axi_bresp          <= 2'b00;

            aw_done            <= 1'b0;
            w_done             <= 1'b0;
            latched_awaddr     <= 32'd0;
            latched_wdata      <= 32'd0;
            latched_wstrb      <= 4'd0;

            irq_out            <= 1'b0;
            cpu_soft_rst_n_out <= 1'b0;
            host_irq_notify    <= 1'b0;
        end else begin
            host_irq_notify <= 1'b0;
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

                case (latched_awaddr[5:0])
                    6'h00: irq_out            <= latched_wdata[0];
                    6'h04: cpu_soft_rst_n_out <= latched_wdata[0];
                    6'h08: host_irq_notify    <= latched_wdata[0];
                    default: ;
                endcase
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

                case (s_axi_lite.araddr[5:0])
                    6'h00:   axi_rdata <= {31'd0, irq_out};
                    6'h04:   axi_rdata <= {31'd0, cpu_soft_rst_n_out};
                    6'h08:   axi_rdata <= gpu_pkg::HW_VERSION_MAJOR;
                    6'h0C:   axi_rdata <= gpu_pkg::HW_VERSION_MINOR;
                    default: axi_rdata <= 32'd0;
                endcase
            end else if (axi_rvalid && s_axi_lite.rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
