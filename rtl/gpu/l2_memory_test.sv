`timescale 1ns / 1ps
// Diagnostic bitstream: select direct L2, L1 or LSU writes without GPC/VRF.
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
    reg [10:0] completed;
    reg [2:0] path;
    wire [31:0] total = path == 0 ? 128 : (path == 1 || path == 3) ? 512 : 1024;
    reg [2:0] seen;
    reg [31:0] first_l1_addr, first_l2_addr, first_axi_addr;
    reg [31:0] run_id;
    wire [0:0] req_ready, rsp_valid;
    wire [255:0] rsp_data [0:0];
    wire [31:0] req_addr [0:0];
    wire [255:0] req_data [0:0];
    wire [31:0] req_strb [0:0];
    assign busy = running;
    // All paths produce the same 4 KiB pattern, using their native request widths.
    wire [31:0] word_index = (path == 1 || path == 3) ? (32'(completed) << 1) : 32'(completed);
    wire [31:0] address = 32'h1000 + (word_index << 2);
    wire [31:0] word0 = 32'h4c320000 ^ word_index;
    wire [31:0] word1 = 32'h4c320000 ^ (word_index + 1);
    wire l1_ready, l1_rsp_valid;
    wire [63:0] l1_rsp_data;
    wire lsu_ready, lsu_l1_valid, lsu_l1_we;
    wire [31:0] lsu_l1_addr;
    wire [63:0] lsu_l1_data;
    wire [7:0] lsu_l1_strb;
    wire l1_valid = path == 1 ? (running && !waiting) : (path >= 2 && lsu_l1_valid);
    wire [31:0] l1_address = path == 1 ? address : lsu_l1_addr;
    wire l1_l2_valid, l1_l2_we;
    wire [31:0] l1_l2_addr, l1_l2_strb;
    wire [255:0] l1_l2_data;
    wire accepted = path == 0 ? req_ready[0] : path == 1 ? l1_ready : lsu_ready;
    wire response = path == 0 ? rsp_valid[0] : path == 1 ? l1_rsp_valid : ctx.valid;
    operand_if op();
    wb_if wb();
    ctx_wb_if ctx();
    assign op.valid = running && !waiting && path >= 2;
    assign op.opcode = 8'ha1;
    assign op.warp_id = '0;
    assign op.pc = '0;
    assign op.active_mask = path == 4 ? 32'd1 : path == 5 ? 32'd2 : 32'd3;
    assign op.rd = '0;
    assign op.imm = 0;
    assign op.is_imm = 0;
    assign op.block_idx_x = 0;
    assign op.block_idx_y = 0;
    assign op.thread_id_start = 0;
    // Inactive lanes deliberately point into guard pages.
    assign op.rs1_data = {path == 4 ? 32'h2000 : path == 3 ? address + 4 : address,
                         path == 5 ? 32'h0 : address};
    assign op.rs2_data = {path == 3 ? word1 : word0, word0};
    lsu u_lsu (
        .clk(clk), .rst_n(rst_n), .op(op), .lsu_ready(lsu_ready),
        .l1_req_valid(lsu_l1_valid), .l1_req_addr(lsu_l1_addr),
        .l1_req_wdata(lsu_l1_data), .l1_req_we(lsu_l1_we), .l1_req_wstrb(lsu_l1_strb),
        .l1_req_ready(l1_ready && path >= 2), .l1_rsp_valid(l1_rsp_valid && path >= 2),
        .l1_rsp_rdata(l1_rsp_data), .wb(wb), .ctx_wb(ctx)
`ifdef ENABLE_GPU_DEBUG
        , .perf_events()
`endif
    );
    l1_cache u_l1 (
        .clk(clk), .rst_n(rst_n), .flush(1'b0), .req_valid(l1_valid),
        .req_addr(l1_address), .req_wdata(path == 1 ? {word1, word0} : lsu_l1_data),
        .req_we(path == 1 ? 1'b1 : lsu_l1_we), .req_wstrb(path == 1 ? 8'hff : lsu_l1_strb),
        .req_ready(l1_ready), .rsp_valid(l1_rsp_valid), .rsp_rdata(l1_rsp_data),
        .l2_req_valid(l1_l2_valid), .l2_req_addr(l1_l2_addr), .l2_req_wdata(l1_l2_data),
        .l2_req_wstrb(l1_l2_strb), .l2_req_we(l1_l2_we), .l2_req_ready(req_ready[0] && path != 0),
        .l2_rsp_valid(rsp_valid[0] && path != 0), .l2_rsp_rdata(rsp_data[0])
`ifdef ENABLE_GPU_DEBUG
        , .perf_events()
`endif
    );
    wire [255:0] direct_data;
    for (genvar lane = 0; lane < 8; lane++) begin : gen_pattern
        assign direct_data[lane*32 +: 32] = 32'h4c320000 ^ ((32'(completed) << 3) + lane);
    end
    assign req_addr[0] = path == 0 ? 32'h1000 + (32'(completed) << 5) : l1_l2_addr;
    assign req_data[0] = path == 0 ? direct_data : l1_l2_data;
    assign req_strb[0] = path == 0 ? 32'hffffffff : l1_l2_strb;
    wire req_valid = path == 0 ? (running && !waiting) : l1_l2_valid;
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
            path <= 0;
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
                s_axi_lite.bresp <= (!running && (awaddr == 8'h14 ||
                    (awaddr == 8'h24 && wstrb[0] && wdata < 6))) ? 2'b00 : 2'b10;
                if (awaddr == 8'h24 && !running && wstrb[0] && wdata < 6) path <= wdata[2:0];
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
                    8'h1c: s_axi_lite.rdata <= {21'd0, completed};
                    8'h20: s_axi_lite.rdata <= run_id;
                    8'h24: s_axi_lite.rdata <= {29'd0, path};
                    8'h28: s_axi_lite.rdata <= 32'h3f; // Supported path IDs 0..5.
                    8'h30: s_axi_lite.rdata <= first_l1_addr;
                    8'h34: s_axi_lite.rdata <= first_l2_addr;
                    8'h38: s_axi_lite.rdata <= first_axi_addr;
                    8'h3c: s_axi_lite.rdata <= {29'd0, seen};
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
            if (!waiting && accepted) waiting <= 1;
            if (m_axi.bvalid && m_axi.bready && m_axi.bresp != 0) error_seen <= 1;
            if (waiting && response) begin
                waiting <= 0;
                completed <= completed + 1'b1;
                if (32'(completed) == total - 1) begin
                    running <= 0;
                    done <= 1;
                end
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seen <= 0;
            first_l1_addr <= 0;
            first_l2_addr <= 0;
            first_axi_addr <= 0;
        end else if (start) begin
            seen <= 0;
            first_l1_addr <= 0;
            first_l2_addr <= 0;
            first_axi_addr <= 0;
        end else if (running) begin
            if (!seen[0] && l1_valid && l1_ready) begin
                seen[0] <= 1;
                first_l1_addr <= l1_address;
            end
            if (!seen[1] && req_valid && req_ready[0]) begin
                seen[1] <= 1;
                first_l2_addr <= req_addr[0];
            end
            if (!seen[2] && m_axi.awvalid && m_axi.awready) begin
                seen[2] <= 1;
                first_axi_addr <= m_axi.awaddr;
            end
        end
    end
    // AXI sideband constants are supplied by rtl/top.sv, as for gpc_top.
    l2_cache #(.NUM_PORTS(1)) u_l2_cache (
        .clk(clk), .rst_n(rst_n), .flush(1'b0),
        .sm_req_valid({req_valid}), .sm_req_we(path == 0 ? 1'b1 : l1_l2_we),
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
