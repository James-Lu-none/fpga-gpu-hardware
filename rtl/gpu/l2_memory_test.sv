`timescale 1ns / 1ps
// Diagnostic bitstream: host-triggered pattern writes through the production L2.
// CTRL BAR0 offsets: 0x10 magic, 0x14 start, 0x18 status, 0x1c completed lines.
module l2_memory_test (
    input wire clk, rst_n,
    axi_lite_if.slave s_axi_lite,
    axi4_if.master m_axi,
    output wire busy
);
    reg aw_pending, w_pending;
    reg [7:0] awaddr;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    reg running, waiting, done, error_seen;
    reg [7:0] completed;
    reg [31:0] run_id;
    wire [0:0] req_ready, rsp_valid;
    wire [255:0] rsp_data [0:0];
    wire [31:0] req_addr [0:0];
    wire [255:0] req_data [0:0];
    wire [31:0] req_strb [0:0];
    assign busy = running;
    assign req_addr[0] = 32'h1000 + (32'(completed) << 5);
    assign req_strb[0] = 32'hffffffff;
    for (genvar word_index = 0; word_index < 8; word_index++) begin : gen_pattern
        assign req_data[0][word_index*32 +: 32] =
            32'h4c320000 ^ ((32'(completed) << 3) + word_index);
    end
    assign s_axi_lite.awready = rst_n && !aw_pending && !s_axi_lite.bvalid;
    assign s_axi_lite.wready = rst_n && !w_pending && !s_axi_lite.bvalid;
    assign s_axi_lite.arready = rst_n && !s_axi_lite.rvalid;
    wire commit_write = aw_pending && w_pending && !s_axi_lite.bvalid;
    wire start = commit_write && awaddr == 8'h14 && wstrb[0] && wdata[0] && !running;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_pending <= 0;
            w_pending <= 0;
            awaddr <= 0;
            wdata <= 0;
            wstrb <= 0;
            s_axi_lite.bvalid <= 0;
            s_axi_lite.bresp <= 0;
            s_axi_lite.rvalid <= 0;
            s_axi_lite.rresp <= 0;
            s_axi_lite.rdata <= 0;
        end else begin
            if (s_axi_lite.awvalid && s_axi_lite.awready) begin
                aw_pending <= 1;
                awaddr <= s_axi_lite.awaddr[7:0];
            end
            if (s_axi_lite.wvalid && s_axi_lite.wready) begin
                w_pending <= 1;
                wdata <= s_axi_lite.wdata;
                wstrb <= s_axi_lite.wstrb;
            end
            if (s_axi_lite.bvalid && s_axi_lite.bready) s_axi_lite.bvalid <= 0;
            if (commit_write) begin
                aw_pending <= 0;
                w_pending <= 0;
                s_axi_lite.bvalid <= 1;
                s_axi_lite.bresp <= (awaddr == 8'h14 && !running) ? 2'b00 : 2'b10;
            end
            if (s_axi_lite.rvalid && s_axi_lite.rready) s_axi_lite.rvalid <= 0;
            if (s_axi_lite.arvalid && s_axi_lite.arready) begin
                s_axi_lite.rvalid <= 1;
                s_axi_lite.rresp <= 0;
                case (s_axi_lite.araddr[7:0])
                    8'h08: s_axi_lite.rdata <= 3; // Preserve driver version reads.
                    8'h0c: s_axi_lite.rdata <= 0;
                    8'h10: s_axi_lite.rdata <= 32'h4c325453; // L2TS
                    8'h18: s_axi_lite.rdata <= {29'd0, error_seen, done, running};
                    8'h1c: s_axi_lite.rdata <= {24'd0, completed};
                    8'h20: s_axi_lite.rdata <= run_id;
                    default: s_axi_lite.rdata <= 0;
                endcase
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 0;
            waiting <= 0;
            done <= 0;
            error_seen <= 0;
            completed <= 0;
            run_id <= 0;
        end else if (start) begin
            run_id <= run_id + 1'b1;
            running <= 1;
            waiting <= 0;
            done <= 0;
            error_seen <= 0;
            completed <= 0;
        end else if (running) begin
            if (!waiting && req_ready[0]) waiting <= 1;
            if (m_axi.bvalid && m_axi.bready && m_axi.bresp != 0) error_seen <= 1;
            if (waiting && rsp_valid[0]) begin
                waiting <= 0;
                completed <= completed + 1'b1;
                if (completed == 127) begin
                    running <= 0;
                    done <= 1;
                end
            end
        end
    end
    // AXI sideband constants are supplied by rtl/top.sv, as for gpc_top.
    l2_cache #(.NUM_PORTS(1)) u_l2_cache (
        .clk(clk), .rst_n(rst_n), .flush(1'b0),
        .sm_req_valid({running && !waiting}), .sm_req_we(1'b1),
        .sm_req_addr(req_addr), .sm_req_wdata(req_data), .sm_req_wstrb(req_strb),
        .sm_req_ready(req_ready), .sm_rsp_valid(rsp_valid), .sm_rsp_rdata(rsp_data),
        .m_axi_awvalid   (m_axi.awvalid),
        .m_axi_awaddr    (m_axi.awaddr),
        .m_axi_awlen     (m_axi.awlen),
        .m_axi_awsize    (m_axi.awsize),
        .m_axi_awburst   (m_axi.awburst),
        .m_axi_awready   (m_axi.awready),
        
        .m_axi_wvalid    (m_axi.wvalid),
        .m_axi_wdata     (m_axi.wdata),
        .m_axi_wstrb     (m_axi.wstrb),
        .m_axi_wlast     (m_axi.wlast),
        .m_axi_wready    (m_axi.wready),
        
        .m_axi_bvalid    (m_axi.bvalid),
        .m_axi_bready    (m_axi.bready),
        
        .m_axi_arvalid   (m_axi.arvalid),
        .m_axi_araddr    (m_axi.araddr),
        .m_axi_arlen     (m_axi.arlen),
        .m_axi_arsize    (m_axi.arsize),
        .m_axi_arburst   (m_axi.arburst),
        .m_axi_arready   (m_axi.arready),
        
        .m_axi_rvalid    (m_axi.rvalid),
        .m_axi_rdata     (m_axi.rdata),
        .m_axi_rlast     (m_axi.rlast),
        .m_axi_rready    (m_axi.rready)
`ifdef ENABLE_GPU_DEBUG
        , .perf_events()
`endif
    );
endmodule
