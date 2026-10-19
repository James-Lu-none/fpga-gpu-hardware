`timescale 1ns / 1ps
import gpu_pkg::*;
module gpc_top_tb;
    reg clk = 0;
    real clock_hz = 125000000.0;
    initial begin
        if ($value$plusargs("clock_hz=%f", clock_hz)) begin end
        if (clock_hz <= 0) $fatal(1, "clock_hz must be positive");
        forever #(500000000.0 / clock_hz) clk = ~clk;
    end
    reg rst_n = 0;
    axi_lite_if control();
    axi4_if #(.DATA_W(256)) vram();
    wire busy, l2_act, irq;
    integer reads, writes;
    gpc_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi_lite(control),
        .m_axi_gmem(vram),
        .gpc_busy(busy),
        .l2_act(l2_act),
        .gpu_completion_irq(irq)
    );
    axi_vram_model memory (
        .clk(clk),
        .rst_n(rst_n),
        .bus(vram),
        .reads(reads),
        .writes(writes)
    );
    integer cycles = 0, max_cycles = 100000;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles >= max_cycles) $fatal(1, "GPC timeout busy=%b irq=%b reads=%0d writes=%0d", busy, irq, reads, writes);
    end
    // Timestamp the actual launch consumption edge and IRQ assertion, rather
    // than AXI-Lite polling or testbench setup/teardown time.
    realtime launch_start_ns = 0.0;
    real launch_to_irq_ns = 0.0;
    integer launch_to_irq_cycles = 0;
    integer execution_fd;
    always @(posedge clk) begin
        if (rst_n && dut.hw_trigger) launch_start_ns = $realtime;
    end
    always @(posedge irq) begin
        launch_to_irq_cycles = int'(($realtime - launch_start_ns) * clock_hz / 1000000000.0);
        launch_to_irq_ns = launch_to_irq_cycles * 1000000000.0 / clock_hz;
        $display("GPC launch-to-IRQ: %0d cycles, %.3f ns (%.6f us) at %.3f MHz",
                 launch_to_irq_cycles, launch_to_irq_ns, launch_to_irq_ns / 1000.0, clock_hz / 1000000.0);
    end
    // Drive at negedge, sample handshakes at posedge. Skew AW/W independently.
    task automatic lite_write(input reg [31:0] addr, data, input integer skew = 0);
        fork
            begin
                @(negedge clk);
                control.awaddr = addr;
                control.awvalid = 1;
                do @(posedge clk); while (!control.awready);
                @(negedge clk);
                control.awvalid = 0;
            end
            begin
                repeat (skew) @(negedge clk);
                @(negedge clk);
                control.wdata = data;
                control.wstrb = 4'hf;
                control.wvalid = 1;
                do @(posedge clk); while (!control.wready);
                @(negedge clk);
                control.wvalid = 0;
            end
        join
        while (!control.bvalid) @(negedge clk);
        if (control.bresp != 0) $fatal(1, "AXI-Lite write failed %h", addr);
        // Check B response hold under host backpressure.
        repeat (2) begin
            @(negedge clk);
            if (!control.bvalid || control.bresp != 0) $fatal(1, "AXI-Lite B response not held");
        end
        control.bready = 1;
        @(posedge clk);
        @(negedge clk);
        control.bready = 0;
    endtask
    task automatic lite_read(input reg [31:0] addr, output reg [31:0] data);
        @(negedge clk);
        control.araddr = addr;
        control.arvalid = 1;
        do @(posedge clk); while (!control.arready);
        @(negedge clk);
        control.arvalid = 0;
        while (!control.rvalid) @(negedge clk);
        data = control.rdata;
        if (control.rresp != 0) $fatal(1, "AXI-Lite read failed %h", addr);
        repeat (2) begin
            @(negedge clk);
            if (!control.rvalid || control.rdata !== data) $fatal(1, "AXI-Lite R response not held");
        end
        control.rready = 1;
        @(posedge clk);
        @(negedge clk);
        control.rready = 0;
    endtask
    task automatic configure(input reg [31:0] addr, data);
        reg [31:0] readback;
        lite_write(addr, data, 2);
        lite_read(addr, readback);
        if (readback !== data) $fatal(1, "Register readback addr=%h got=%h expected=%h", addr, readback, data);
    endtask
`ifdef ENABLE_GPU_DEBUG
    reg [31:0] counters [0:PERF_COUNT-1];
    reg [31:0] first_retired;
    integer counter_fd;
    integer observed_issue = 0, observed_retired = 0, observed_divergence = 0;
    reg observing = 0;
    wire [NUM_SMS*NUM_SUB_PARTITIONS-1:0] observed_issue_pulse, observed_retire_pulse, observed_divergence_pulse;
    for (genvar sm = 0; sm < NUM_SMS; sm++) begin : perf_monitor_sm
        for (genvar sp = 0; sp < NUM_SUB_PARTITIONS; sp++) begin : perf_monitor_sp
            assign observed_issue_pulse[sm*NUM_SUB_PARTITIONS+sp] = dut.gen_sm_array[sm].u_sm.gen_sub_partitions[sp].u_sp.issue.valid;
            always @(posedge clk) begin
                if ($test$plusargs("trace_alloc") && dut.gen_sm_array[sm].u_sm.alloc[sp].valid && dut.gen_sm_array[sm].u_sm.alloc[sp].ready)
                    $display("ALLOC sm=%0d sp=%0d group=%0d,%0d", sm, sp,
                        dut.gen_sm_array[sm].u_sm.alloc[sp].block_idx_x,
                        dut.gen_sm_array[sm].u_sm.alloc[sp].block_idx_y);
            end
            assign observed_divergence_pulse[sm*NUM_SUB_PARTITIONS+sp] =
                dut.gen_sm_array[sm].u_sm.gen_sub_partitions[sp].u_sp.ctx_wb.valid &&
                dut.gen_sm_array[sm].u_sm.gen_sub_partitions[sp].u_sp.ctx_wb.is_divergent;
            assign observed_retire_pulse[sm*NUM_SUB_PARTITIONS+sp] = dut.gen_sm_array[sm].u_sm.gen_sub_partitions[sp].u_sp.ctx_wb.valid;
        end
    end
    always @(posedge clk) begin
        if (dut.hw_trigger) begin
            observed_issue <= 0;
            observed_retired <= 0;
            observed_divergence <= 0;
            observing <= 1;
        end else if (observing) begin
            observed_issue <= observed_issue + $countones(observed_issue_pulse);
            observed_retired <= observed_retired + $countones(observed_retire_pulse);
            observed_divergence <= observed_divergence + $countones(observed_divergence_pulse);
            if (dut.grid_done_status) observing <= 0;
        end
    end
    task automatic check_counters;
        reg [31:0] saved;
        for (int c = 0; c < PERF_COUNT; c++) lite_read(32'h30 + 32'(c*4), counters[c]);
        if (counters[PERF_CYCLE] == 0 || counters[PERF_CYCLE] != 32'(launch_to_irq_cycles) || counters[PERF_INST_RETIRED] != 32'(observed_retired) ||
            counters[PERF_WARP_ISSUE] != 32'(observed_issue) ||
            counters[PERF_WARP_ISSUE] != counters[PERF_INST_RETIRED] ||
            counters[PERF_WARP_DONE] != 32'(grid_x*grid_y)) $fatal(1, "Counter issue/retire/warp totals mismatch");
        if (counters[PERF_L1_REQ] != counters[PERF_L1_HIT]+counters[PERF_L1_MISS] ||
            counters[PERF_L2_REQ] != counters[PERF_L2_HIT]+counters[PERF_L2_MISS] ||
            counters[PERF_L1_REQ] == 0 || counters[PERF_L2_REQ] == 0 ||
            counters[PERF_LSU_FIFO_PUSH] != counters[PERF_LSU_FIFO_POP] ||
            counters[PERF_LSU_FIFO_PUSH] == 0 || counters[PERF_WARP_SWAP] >= counters[PERF_WARP_ISSUE])
            $fatal(1, "Counter cache/FIFO/swap invariants mismatch");
        repeat (20) @(negedge clk);
        for (int c = 0; c < PERF_COUNT; c++) begin
            lite_read(32'h30+32'(c*4), saved);
            if (saved !== counters[c]) $fatal(1, "Counter changed after completion index=%0d", c);
        end
    endtask
`endif
    string program_path, config_path, dump_path, trace_path;
    integer fd, rc, count;
    reg [31:0] instruction, status;
    integer grid_x, grid_y, block_x, block_y;
    reg [31:0] src_addr, dst_addr;
    initial begin
        rc = $value$plusargs("max_cycles=%d", max_cycles);
        if (!$value$plusargs("program=%s", program_path) ||
            !$value$plusargs("config=%s", config_path) || !$value$plusargs("dump=%s", dump_path))
            $fatal(1, "Requires +program +config +memory +dump");
        if ($value$plusargs("trace=%s", trace_path)) begin
            $dumpfile(trace_path);
            $dumpvars(0, gpc_top_tb);
        end
        control.awaddr = 0; control.awprot = 0; control.awvalid = 0;
        control.wdata = 0; control.wstrb = 0; control.wvalid = 0; control.bready = 0;
        control.araddr = 0; control.arprot = 0; control.arvalid = 0; control.rready = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (10) @(negedge clk);
        fd = $fopen(config_path, "r");
        if (fd == 0) $fatal(1, "Cannot open GPC launch config");
        rc = $fscanf(fd, "%d %d %d %d %h %h", grid_x, grid_y, block_x, block_y, src_addr, dst_addr);
        $fclose(fd);
        if (rc != 6 || grid_x < 1 || grid_x > 65535 || grid_y < 1 || grid_y > 65535 || block_x != 2 || block_y != 1)
            $fatal(1, "Unsupported GPC launch configuration");
        fd = $fopen(program_path, "r");
        if (fd == 0) $fatal(1, "Cannot open kernel");
        count = 0;
        while (!$feof(fd)) begin
            rc = $fscanf(fd, "%h", instruction);
            if (rc == 1) begin
                if (count >= IRAM_DEPTH) $fatal(1, "Kernel exceeds I-RAM");
                lite_write(32'h1000 + 32'(count*4), instruction, count % 3);
                count++;
            end else if (!$feof(fd)) $fatal(1, "Malformed kernel");
        end
        $fclose(fd);
        if (!count) $fatal(1, "Empty kernel");
        // Existing I-RAM aperture is write-only; reads return zero.
        lite_read(32'h1000, status);
        if (status != 0) $fatal(1, "Unexpected I-RAM read response");
        configure(32'h0c, 32'(grid_x));
        configure(32'h10, 32'(grid_y));
        configure(32'h14, 32'(block_x));
        configure(32'h18, 32'(block_y));
        configure(32'h20, src_addr);
        configure(32'h24, dst_addr);
        lite_write(32'h08, 1);
        lite_read(32'h04, status);
        if (status != 0 || irq) $fatal(1, "Completion not cleared before launch");
        lite_write(32'h00, 1);
        do lite_read(32'h04, status); while (!status[0]);
        if (!irq || busy) $fatal(1, "Invalid GPC completion state");
        if (!reads || !writes) $fatal(1, "Kernel did not exercise AXI VRAM reads/writes");
        lite_write(32'h08, 1);
        lite_read(32'h04, status);
        if (status != 0 || irq) $fatal(1, "INT_ACK did not clear completion");
`ifdef ENABLE_GPU_DEBUG
        check_counters();
        first_retired = counters[PERF_INST_RETIRED];
        // A second launch must reset the bank rather than accumulate both runs.
        lite_write(32'h00, 1);
        do lite_read(32'h04, status); while (!status[0]);
        check_counters();
        if (counters[PERF_INST_RETIRED] != first_retired) $fatal(1, "Launch did not reset counters");
        counter_fd = $fopen("counters.txt", "w");
        if (counter_fd == 0) $fatal(1, "Cannot open counters.txt");
        $fwrite(counter_fd, "cycle_count: %0d\n", counters[0]);
        $fwrite(counter_fd, "inst_retired_count: %0d\n", counters[1]);
        $fwrite(counter_fd, "warp_issue_count: %0d\n", counters[2]);
        $fwrite(counter_fd, "warp_swap_count: %0d\n", counters[3]);
        $fwrite(counter_fd, "l1_req_count: %0d\n", counters[4]);
        $fwrite(counter_fd, "l1_hit_count: %0d\n", counters[5]);
        $fwrite(counter_fd, "l1_miss_count: %0d\n", counters[6]);
        $fwrite(counter_fd, "l2_req_count: %0d\n", counters[7]);
        $fwrite(counter_fd, "l2_hit_count: %0d\n", counters[8]);
        $fwrite(counter_fd, "l2_miss_count: %0d\n", counters[9]);
        $fwrite(counter_fd, "lsu_fifo_push_count: %0d\n", counters[10]);
        $fwrite(counter_fd, "lsu_fifo_pop_count: %0d\n", counters[11]);
        $fwrite(counter_fd, "simt_stack_push_count: %0d\n", counters[12]);
        $fwrite(counter_fd, "simt_stack_pop_count: %0d\n", counters[13]);
        $fwrite(counter_fd, "lsu_wait_cycles_count: %0d\n", counters[14]);
        $fwrite(counter_fd, "lsu_fifo_full_cycles_count: %0d\n", counters[15]);
        $fwrite(counter_fd, "axi_read_stall_cycles_count: %0d\n", counters[16]);
        $fwrite(counter_fd, "axi_write_stall_cycles_count: %0d\n", counters[17]);
        $fwrite(counter_fd, "warp_done_count: %0d\n", counters[18]);
        $fclose(counter_fd);
        lite_write(32'h08, 1);
        lite_write(32'h2c, 1);
        for (int c = 0; c < PERF_COUNT; c++) begin
            lite_read(32'h30+32'(c*4), status);
            if (status != 0) $fatal(1, "Manual counter clear failed index=%0d", c);
        end
`endif
        execution_fd = $fopen("execution.txt", "w");
        if (execution_fd == 0) $fatal(1, "Cannot open execution.txt");
`ifdef ENABLE_GPU_DEBUG
        $fwrite(execution_fd, "divergence_events: %0d\n", observed_divergence);
`endif
        $fwrite(execution_fd, "clock_hz: %.0f\n", clock_hz);
        $fwrite(execution_fd, "clock_period_ns: %.6f\n", 1000000000.0 / clock_hz);
        $fwrite(execution_fd, "launch_to_irq_cycles: %0d\n", launch_to_irq_cycles);
        $fwrite(execution_fd, "launch_to_irq_time_ns: %.3f\n", launch_to_irq_ns);
        $fwrite(execution_fd, "launch_to_irq_time_us: %.6f\n", launch_to_irq_ns / 1000.0);
        $fclose(execution_fd);
        memory.dump(dump_path);
        $display("PASS GPC grid=%0dx%0d block=%0dx%0d instructions=%0d AXI reads=%0d writes=%0d cycles=%0d",
                 grid_x, grid_y, block_x, block_y, count, reads, writes, cycles);
        $finish;
    end
endmodule
