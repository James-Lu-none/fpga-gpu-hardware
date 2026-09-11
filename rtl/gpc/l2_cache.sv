`timescale 1ns / 1ps
// GPC L2 Shared Cache & AXI4 Master
// Services L1 misses from NUM_PORTS SMs and interfaces with DDR3 via AXI4.
// Capacity: 16KB (512 lines x 32 Bytes) Direct Mapped, Write-Through

import gpu_pkg::*;

module l2_cache #(
    parameter NUM_PORTS = gpu_pkg::NUM_SMS
)(
    input wire clk,
    input wire rst_n,

    // Vectorized L1 Cache Interfaces (From NUM_PORTS SMs)
    input  wire [NUM_PORTS-1:0] sm_req_valid,
    input  wire [31:0] sm_req_addr  [0:NUM_PORTS-1],
    input  wire [255:0] sm_req_wdata [0:NUM_PORTS-1],
    input  wire [31:0] sm_req_wstrb [0:NUM_PORTS-1],
    input  wire [NUM_PORTS-1:0] sm_req_we,
    output wire [NUM_PORTS-1:0] sm_req_ready,
    output reg  [NUM_PORTS-1:0] sm_rsp_valid,
    output reg  [255:0] sm_rsp_rdata [0:NUM_PORTS-1],

    // AXI4-Full Master Interface (To DDR3)
    output reg m_axi_awvalid,
    output reg [31:0] m_axi_awaddr,
    output reg [7:0] m_axi_awlen,
    output reg [2:0] m_axi_awsize,
    output reg [1:0] m_axi_awburst,
    input wire m_axi_awready,

    output reg m_axi_wvalid,
    output reg [255:0]m_axi_wdata,
    output reg [31:0] m_axi_wstrb,
    output reg m_axi_wlast,
    input wire m_axi_wready,

    input wire m_axi_bvalid,
    output reg m_axi_bready,

    output reg m_axi_arvalid,
    output reg [31:0] m_axi_araddr,
    output reg [7:0] m_axi_arlen,
    output reg [2:0] m_axi_arsize,
    output reg [1:0] m_axi_arburst,
    input wire m_axi_arready,

    input wire m_axi_rvalid,
    input wire [255:0]m_axi_rdata,
    input wire m_axi_rlast,
    output reg m_axi_rready
);

    // Round-Robin Arbiter for L1 Requests
    localparam PORT_SEL_W = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1;
    reg [PORT_SEL_W-1:0] current_sm;

    wire req_valid = sm_req_valid[current_sm];
    wire [31:0] req_addr  = sm_req_addr[current_sm];
    wire [255:0]req_wdata = sm_req_wdata[current_sm];
    wire [31:0] req_wstrb = sm_req_wstrb[current_sm];
    wire req_we    = sm_req_we[current_sm];

    reg req_ready_internal;
    for (genvar p = 0; p < NUM_PORTS; p = p + 1) begin : gen_sm_req_ready
        assign sm_req_ready[p] = (current_sm == p) ? req_ready_internal : 1'b0;
    end

    // Cache Parameters & Storage
    // 32-bit Address = [31:14] Tag (18 bits) | [13:5] Index (9 bits) | [4:0] Offset (5 bits)
    // 512 lines * 32 Bytes = 16KB
    localparam NUM_LINES = 512;
    wire [17:0] req_tag   = req_addr[31:14];
    wire [8:0]  req_index = req_addr[13:5];
    
    (* ram_style = "block" *) reg [17:0] tag_ram [0:NUM_LINES-1];
    (* ram_style = "block" *) reg valid_ram [0:NUM_LINES-1];

    reg [17:0] tag_ram_dout;
    reg valid_ram_dout;
    
    reg tag_ram_we;
    reg [17:0] tag_ram_wdata;
    
    reg valid_ram_we;
    reg valid_ram_wdata;

    integer i;
    initial begin
        for (i = 0; i < NUM_LINES; i = i + 1) begin
            valid_ram[i] = 1'b0;
            tag_ram[i]   = 18'd0;
        end
    end

    // Strict BRAM Template for Data RAM (Vivado Inference)
    (* ram_style = "block" *) reg [255:0] data_ram [0:NUM_LINES-1];
    reg [255:0] data_ram_dout;
    reg data_ram_we;
    reg [255:0] data_ram_wdata;
    
    // Latched request for pipeline
    reg [31:0]  latched_req_addr;
    reg [255:0] latched_req_wdata;
    reg [31:0]  latched_req_wstrb;
    reg         latched_req_we;
    reg [17:0]  latched_req_tag;
    reg [8:0]   latched_req_index;

    // FSM States
    localparam STATE_IDLE       = 3'd0;
    localparam STATE_COMPARE    = 3'd1;
    localparam STATE_HIT_RETURN = 3'd2;
    localparam STATE_AXI_AR     = 3'd3;
    localparam STATE_AXI_R      = 3'd4;
    localparam STATE_AXI_AW     = 3'd5;
    localparam STATE_AXI_W      = 3'd6;
    localparam STATE_AXI_B      = 3'd7;

    reg [2:0] state;

    wire [8:0] ram_addr = (state == STATE_IDLE) ? req_index : latched_req_index;

    always @(posedge clk) begin
        if (data_ram_we) begin
            data_ram[ram_addr] <= data_ram_wdata;
        end
        data_ram_dout <= data_ram[ram_addr];
        
        if (tag_ram_we) begin
            tag_ram[ram_addr] <= tag_ram_wdata;
        end
        tag_ram_dout <= tag_ram[ram_addr];

        if (valid_ram_we) begin
            valid_ram[ram_addr] <= valid_ram_wdata;
        end
        valid_ram_dout <= valid_ram[ram_addr];
    end

    function [PORT_SEL_W-1:0] next_port(input [PORT_SEL_W-1:0] curr);
        if (NUM_PORTS <= 1) return '0;
        else if (curr == NUM_PORTS - 1) return '0;
        else return curr + 1'b1;
    endfunction

    // Controller FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            req_ready_internal <= 1'b1;
            current_sm <= '0;
            sm_rsp_valid <= '0;
            for (int p = 0; p < NUM_PORTS; p = p + 1) begin
                sm_rsp_rdata[p] <= 256'd0;
            end
            
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid <= 1'b0;
            m_axi_bready <= 1'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_rready <= 1'b0;
            
            data_ram_we <= 1'b0;
            valid_ram_we <= 1'b0;
            tag_ram_we <= 1'b0;
        end else begin
            data_ram_we <= 1'b0;
            valid_ram_we <= 1'b0;
            tag_ram_we <= 1'b0;
            sm_rsp_valid <= '0;

            case (state)
                STATE_IDLE: begin
                    if (req_valid && req_ready_internal) begin
                        req_ready_internal <= 1'b0;
                        
                        // Latch request to break timing path from arbiter (current_sm)
                        latched_req_addr <= req_addr;
                        latched_req_wdata <= req_wdata;
                        latched_req_wstrb <= req_wstrb;
                        latched_req_we <= req_we;
                        latched_req_tag <= req_tag;
                        latched_req_index <= req_index;
                        
                        state <= STATE_COMPARE;
                    end else begin
                        // Rotate arbiter if current port has no request
                        if (!req_valid && NUM_PORTS > 1) begin
                            current_sm <= next_port(current_sm);
                        end
                    end
                end

                STATE_COMPARE: begin
                    // Check Hit
                    if (valid_ram_dout && (tag_ram_dout == latched_req_tag)) begin
                        // L2 HIT
                        if (latched_req_we) begin
                            // Write-Through to DDR3
                            valid_ram_we <= 1'b1;
                            valid_ram_wdata <= 1'b0; // Invalidate L2 on write
                            
                            m_axi_awvalid <= 1'b1;
                            m_axi_awaddr <= latched_req_addr; // Address is 32-byte aligned from L1
                            m_axi_awlen <= 8'd0; // 1 beat of 256-bit
                            m_axi_awsize <= 3'b101; // 2^5 = 32 bytes
                            m_axi_awburst <= 2'b01; // INCR
                            state <= STATE_AXI_AW;
                        end else begin
                            // Read Hit
                            state <= STATE_HIT_RETURN;
                        end
                    end else begin
                        // L2 MISS
                        if (latched_req_we) begin
                            // Write-Miss: Send directly to DDR3
                            m_axi_awvalid <= 1'b1;
                            m_axi_awaddr <= latched_req_addr;
                            m_axi_awlen <= 8'd0;
                            m_axi_awsize <= 3'b101;
                            m_axi_awburst <= 2'b01;
                            state <= STATE_AXI_AW;
                        end else begin
                            // Read-Miss: Fetch from DDR3
                            m_axi_arvalid <= 1'b1;
                            m_axi_araddr <= latched_req_addr;
                            m_axi_arlen <= 8'd0; // 1 beat of 256-bit
                            m_axi_arsize <= 3'b101; // 32 bytes
                            m_axi_arburst <= 2'b01; // INCR
                            state <= STATE_AXI_AR;
                        end
                    end
                end

                STATE_HIT_RETURN: begin
                    sm_rsp_valid[current_sm] <= 1'b1;
                    sm_rsp_rdata[current_sm] <= data_ram_dout;
                    req_ready_internal <= 1'b1;
                    if (NUM_PORTS > 1) current_sm <= next_port(current_sm);
                    state <= STATE_IDLE;
                end

                // --- READ PATH ---
                STATE_AXI_AR: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready <= 1'b1;
                        state <= STATE_AXI_R;
                    end
                end
                STATE_AXI_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        m_axi_rready <= 1'b0;
                        // Refill L2 Cache
                        valid_ram_we <= 1'b1;
                        valid_ram_wdata <= 1'b1;
                        tag_ram_we <= 1'b1;
                        tag_ram_wdata <= latched_req_tag;
                        
                        data_ram_we <= 1'b1;
                        data_ram_wdata <= m_axi_rdata;
                        
                        // Return to L1
                        sm_rsp_valid[current_sm] <= 1'b1;
                        sm_rsp_rdata[current_sm] <= m_axi_rdata;
                        
                        req_ready_internal <= 1'b1;
                        if (NUM_PORTS > 1) current_sm <= next_port(current_sm);
                        state <= STATE_IDLE;
                    end
                end

                // --- WRITE PATH ---
                STATE_AXI_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid <= 1'b1;
                        m_axi_wdata <= latched_req_wdata;
                        m_axi_wstrb <= latched_req_wstrb;
                        m_axi_wlast <= 1'b1;
                        state <= STATE_AXI_W;
                    end
                end
                STATE_AXI_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        m_axi_wvalid <= 1'b0;
                        m_axi_wlast <= 1'b0;
                        state <= STATE_AXI_B;
                    end
                end
                STATE_AXI_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        // Write complete
                        sm_rsp_valid[current_sm] <= 1'b1; // ACK
                        req_ready_internal <= 1'b1;
                        if (NUM_PORTS > 1) current_sm <= next_port(current_sm);
                        state <= STATE_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
