`timescale 1ns/1ps
`include "gpu_defines.vh"

module sm_commit_tb;
    reg clk = 0;
    always #4 clk = ~clk; // 125 MHz clock (8 ns period)

    reg rst_n = 0;
    reg block_issue_valid = 0;
    reg [15:0] block_idx_x = 0;
    reg [15:0] block_idx_y = 0;
    reg [9:0]  warps_per_block = 0;
    wire block_accepted;
    wire [4:0] available_warp_slots;
    wire sm_idle;

    // Cache stub signals
    wire l1_req_valid;
    wire [31:0] l1_req_addr;
    wire [255:0] l1_req_wdata;
    wire [31:0] l1_req_wstrb;
    wire l1_req_we;
    reg  l1_req_ready = 1'b1;
    reg  l1_rsp_valid = 1'b0;
    reg  [255:0] l1_rsp_rdata = '0;

`ifdef ENABLE_GPU_DEBUG
    reg perf_clear = 0;
    wire [31:0] perf_increments [0:`PERF_COUNT-1];
`endif

    streaming_multiprocessor dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush(1'b0),
        .block_issue_valid(block_issue_valid),
        .block_idx_x(block_idx_x),
        .block_idx_y(block_idx_y),
        .warps_per_block(warps_per_block),
        .threads_per_block(16'd0),
        .block_dim_x(16'd0),
        .block_accepted(block_accepted),
        .available_warp_slots(available_warp_slots),
        .sm_idle(sm_idle),
        .dma_src_addr(32'd0),
        .dma_dst_addr(32'd0),
        .iram_we(1'b0),
        .iram_waddr(12'd0),
        .iram_wdata(32'd0),
        .l1_req_valid(l1_req_valid),
        .l1_req_addr(l1_req_addr),
        .l1_req_wdata(l1_req_wdata),
        .l1_req_wstrb(l1_req_wstrb),
        .l1_req_we(l1_req_we),
        .l1_req_ready(l1_req_ready),
        .l1_rsp_valid(l1_rsp_valid),
        .l1_rsp_rdata(l1_rsp_rdata)
`ifdef ENABLE_GPU_DEBUG
        , .perf_clear(perf_clear),
        .perf_increments(perf_increments)
`endif
    );

    // Mock TBS issue task
    task automatic issue_block(
        input [15:0] bx,
        input [15:0] by,
        input [9:0]  w_cnt,
        output int   elapsed_cycles
    );
        int c;
        @(negedge clk);
        block_issue_valid = 1'b1;
        block_idx_x       = bx;
        block_idx_y       = by;
        warps_per_block   = w_cnt;
        c = 0;

        // TBS waits for block_accepted
        while (!block_accepted) begin
            @(negedge clk);
            c++;
            if (c > 50) $fatal(1, "Timeout waiting for block_accepted for block [%0d,%0d]", bx, by);
        end

        // Acknowledged! TBS deasserts valid on the next clock
        block_issue_valid = 1'b0;
        elapsed_cycles = c;
        @(negedge clk);
    endtask

    int cycles;
    initial begin
        // Reset sequence
        @(negedge clk);
        rst_n = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (5) @(negedge clk);

        // Initially all 4 SPs have 8 warps each -> 32 warps (saturated to 31 in 5-bit)
        if (available_warp_slots != 5'd31)
            $fatal(1, "Initial available_warp_slots mismatch: expected 31, got %0d", available_warp_slots);

        // Test 1: Single-warp block -> Must commit in exactly 1 cycle to SP 0!
        $display("[Test 1] Dispatch 1-warp block [0,0]");
        issue_block(16'd0, 16'd0, 10'd1, cycles);
        if (cycles != 1) $fatal(1, "Test 1: Expected 1-cycle commit, took %0d cycles", cycles);
        if (dut.sp_rr_ptr != 2'd1) $fatal(1, "Test 1: Expected sp_rr_ptr=1, got %0d", dut.sp_rr_ptr);

        // Test 2: Single-warp block -> Must commit in exactly 1 cycle to SP 1!
        $display("[Test 2] Dispatch 1-warp block [1,0]");
        issue_block(16'd1, 16'd0, 10'd1, cycles);
        if (cycles != 1) $fatal(1, "Test 2: Expected 1-cycle commit, took %0d cycles", cycles);
        if (dut.sp_rr_ptr != 2'd2) $fatal(1, "Test 2: Expected sp_rr_ptr=2, got %0d", dut.sp_rr_ptr);

        // Test 3: 2-warp block -> Must commit warps to SP 2 and SP 3 in parallel in exactly 1 cycle!
        $display("[Test 3] Dispatch 2-warp block [2,0]");
        issue_block(16'd2, 16'd0, 10'd2, cycles);
        if (cycles != 1) $fatal(1, "Test 3: Expected 1-cycle parallel commit, took %0d cycles", cycles);
        if (dut.sp_rr_ptr != 2'd0) $fatal(1, "Test 3: Expected sp_rr_ptr wrapped to 0, got %0d", dut.sp_rr_ptr);

        // Test 4: 4-warp block -> Full parallel commit across all 4 SPs simultaneously in 1 cycle!
        $display("[Test 4] Dispatch 4-warp block [3,0] in parallel");
        issue_block(16'd3, 16'd0, 10'd4, cycles);
        if (cycles != 1) $fatal(1, "Test 4: Expected 1-cycle 4-warp parallel commit, took %0d cycles", cycles);
        if (dut.sp_rr_ptr != 2'd0) $fatal(1, "Test 4: Expected sp_rr_ptr=0, got %0d", dut.sp_rr_ptr);

        // Test 5: 8-warp block -> Sliced commit: 2 cycles (4 warps per cycle)!
        $display("[Test 5] Dispatch 8-warp block [0,1] across 2 parallel slices");
        issue_block(16'd0, 16'd1, 10'd8, cycles);
        if (cycles != 2) $fatal(1, "Test 5: Expected 2-cycle commit for 8 warps, took %0d cycles", cycles);
        if (dut.sp_rr_ptr != 2'd0) $fatal(1, "Test 5: Expected sp_rr_ptr=0, got %0d", dut.sp_rr_ptr);

        // Test 6: 6-warp block -> Slices: 4 warps cycle 1, 2 warps cycle 2 (starting at SP 0)
        $display("[Test 6] Dispatch 6-warp block [1,1] (4 + 2 warps)");
        issue_block(16'd1, 16'd1, 10'd6, cycles);
        if (cycles != 2) $fatal(1, "Test 6: Expected 2-cycle commit for 6 warps, took %0d cycles", cycles);
        if (dut.sp_rr_ptr != 2'd2) $fatal(1, "Test 6: Expected sp_rr_ptr=2, got %0d", dut.sp_rr_ptr);

        // Total allocated warps: 1 + 1 + 2 + 4 + 8 + 6 = 22 warps.
        // Total capacity = 32. Remaining free = 32 - 22 = 10 slots.
        repeat (3) @(negedge clk);
        if (available_warp_slots != 5'd10)
            $fatal(1, "Test 7: Expected available_warp_slots=10, got %0d", available_warp_slots);

        $display("PASS Parallel CTA Commit verification (all 1-cycle and multi-cycle parallel tests passed)");
        $finish;
    end

    initial begin
        #50000;
        $fatal(1, "TIMEOUT in sm_commit_tb");
    end
endmodule
