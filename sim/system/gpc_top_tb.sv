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

    // SM-SP Arbiter & Allocation Signal Monitor
    bit trace_arbiter = 1;
    initial begin
        if ($test$plusargs("no_trace_arb")) trace_arbiter = 0;
    end

    function automatic string rx_state_name(input [2:0] st);
        case (st)
            3'd0: return "ST_IDLE";
            3'd1: return "ST_ISSUE_WARP";
            3'd2: return "ST_WAIT_WARP";
            3'd3: return "ST_NEXT_WARP";
            default: return "UNKNOWN";
        endcase
    endfunction

    function automatic string tbs_state_name(input [1:0] st);
        case (st)
            2'd0: return "IDLE";
            2'd1: return "ISSUE";
            2'd2: return "WAIT_ACK";
            2'd3: return "WAIT_DONE";
            default: return "UNKNOWN";
        endcase
    endfunction

    function automatic string lsu_state_name(input [1:0] st);
        case (st)
            2'd0: return "LSU_IDLE";
            2'd1: return "LSU_ISSUE";
            2'd2: return "LSU_WAIT";
            default: return "UNKNOWN";
        endcase
    endfunction

    // TBS Launch & Completion Monitor
    reg [1:0] prev_tbs_state;
    reg prev_all_idle;
    reg prev_grid_done;
    reg [NUM_SMS-1:0] prev_sm_issue_valid;
    reg [NUM_SMS-1:0] prev_sm_accepted;

    always @(posedge clk) begin
        if (!rst_n) begin
            prev_tbs_state       <= 2'd0;
            prev_all_idle        <= 1'b0;
            prev_grid_done       <= 1'b0;
            prev_sm_issue_valid  <= '0;
            prev_sm_accepted     <= '0;
        end else if (trace_arbiter) begin
            if (dut.u_scheduler.state != prev_tbs_state) begin
                $display("[Cycle %0d] [TBS_STATE] %s -> %s (found=%b, best_sm=%0d, max_slots=%0d)",
                         cycles, tbs_state_name(prev_tbs_state), tbs_state_name(dut.u_scheduler.state),
                         dut.u_scheduler.sm_found, dut.u_scheduler.best_sm, dut.u_scheduler.max_slots);
                prev_tbs_state <= dut.u_scheduler.state;
            end
            if (!prev_all_idle && dut.u_scheduler.all_idle) begin
                $display("[Cycle %0d] [ASSERT] TBS: all_idle ASSERTED! (state=%s, sm0_slots=%0d, sm1_slots=%0d, MAX_WARPS=%0d)",
                         cycles, tbs_state_name(dut.u_scheduler.state),
                         dut.gen_sm_array[0].u_sm.available_warp_slots,
                         (NUM_SMS > 1 ? dut.gen_sm_array[1].u_sm.available_warp_slots : 5'd0),
                         gpu_pkg::MAX_WARPS);
            end
            prev_all_idle <= dut.u_scheduler.all_idle;

            if (!prev_grid_done && dut.u_scheduler.grid_done) begin
                $display("[Cycle %0d] [ASSERT] TBS: grid_done ASSERTED!", cycles);
            end
            prev_grid_done <= dut.u_scheduler.grid_done;

            for (int s = 0; s < NUM_SMS; s++) begin
                if (!prev_sm_issue_valid[s] && dut.u_scheduler.sm_block_issue_valid[s]) begin
                    $display("[Cycle %0d] [ASSERT] TBS -> SM%0d: sm_block_issue_valid ASSERTED (block=[%0d,%0d], warps=%0d)",
                             cycles, s, dut.u_scheduler.sm_block_idx_x, dut.u_scheduler.sm_block_idx_y, dut.u_scheduler.sm_warps_per_block);
                end
                if (!prev_sm_accepted[s] && dut.sm_block_accepted[s]) begin
                    $display("[Cycle %0d] [ASSERT] SM%0d -> TBS: sm_block_accepted ASSERTED", cycles, s);
                end
                prev_sm_issue_valid[s] <= dut.u_scheduler.sm_block_issue_valid[s];
                prev_sm_accepted[s]    <= dut.sm_block_accepted[s];
            end
        end
    end

    // SM & SP Arbiter / Allocation Monitors
    for (genvar sm = 0; sm < NUM_SMS; sm++) begin : mon_sm_block
        reg [2:0] prev_rx_state;
        reg prev_block_accepted;
        reg prev_alloc_valid;
        reg [4:0] prev_avail_slots;
        integer prev_alloc_target_sp;

        reg prev_l1_req_valid_int;
        reg prev_l1_rsp_valid_int;
        reg prev_sm_l1_req_valid;
        reg prev_sm_l1_rsp_valid;

        always @(posedge clk) begin
            if (!rst_n) begin
                prev_rx_state          <= 3'd0;
                prev_block_accepted    <= 1'b0;
                prev_alloc_valid       <= 1'b0;
                prev_avail_slots       <= 5'd0;
                prev_alloc_target_sp   <= '0;
                prev_l1_req_valid_int  <= 1'b0;
                prev_l1_rsp_valid_int  <= 1'b0;
                prev_sm_l1_req_valid   <= 1'b0;
                prev_sm_l1_rsp_valid   <= 1'b0;
            end else if (trace_arbiter) begin
                // rx_state transition
                if (dut.gen_sm_array[sm].u_sm.rx_state != prev_rx_state) begin
                    $display("[Cycle %0d] [SM%0d_RX_STATE] %s -> %s (warp_cnt=%0d/%0d, target_sp=%0d, alloc_ready=%b, max_free_slots=%0d)",
                             cycles, sm, rx_state_name(prev_rx_state),
                             rx_state_name(dut.gen_sm_array[sm].u_sm.rx_state),
                             dut.gen_sm_array[sm].u_sm.warp_cnt,
                             dut.gen_sm_array[sm].u_sm.accepted_warps_per_block,
                             dut.gen_sm_array[sm].u_sm.alloc_target_sp,
                             dut.gen_sm_array[sm].u_sm.alloc_ready,
                             dut.gen_sm_array[sm].u_sm.max_free_slots);
                    prev_rx_state <= dut.gen_sm_array[sm].u_sm.rx_state;
                end

                // block_accepted
                if (!prev_block_accepted && dut.gen_sm_array[sm].u_sm.block_accepted) begin
                    $display("[Cycle %0d] [ASSERT] SM%0d: block_accepted ASSERTED", cycles, sm);
                end
                prev_block_accepted <= dut.gen_sm_array[sm].u_sm.block_accepted;

                // alloc_valid_reg
                if (!prev_alloc_valid && dut.gen_sm_array[sm].u_sm.alloc_valid_reg) begin
                    $display("[Cycle %0d] [ASSERT] SM%0d: alloc_valid_reg ASSERTED (target_sp=%0d, alloc_ready=%b, warp_cnt=%0d)",
                             cycles, sm, dut.gen_sm_array[sm].u_sm.alloc_target_sp,
                             dut.gen_sm_array[sm].u_sm.alloc_ready,
                             dut.gen_sm_array[sm].u_sm.warp_cnt);
                end
                prev_alloc_valid <= dut.gen_sm_array[sm].u_sm.alloc_valid_reg;

                // available_warp_slots
                if (dut.gen_sm_array[sm].u_sm.available_warp_slots != prev_avail_slots) begin
                    $display("[Cycle %0d] [SLOTS] SM%0d: available_warp_slots changed %0d -> %0d (max_free_slots=%0d, rx_state=%s)",
                             cycles, sm, prev_avail_slots,
                             dut.gen_sm_array[sm].u_sm.available_warp_slots,
                             dut.gen_sm_array[sm].u_sm.max_free_slots,
                             rx_state_name(dut.gen_sm_array[sm].u_sm.rx_state));
                    prev_avail_slots <= dut.gen_sm_array[sm].u_sm.available_warp_slots;
                end

                // alloc_target_sp
                if (int'(dut.gen_sm_array[sm].u_sm.alloc_target_sp) != prev_alloc_target_sp) begin
                    $display("[Cycle %0d] [ALLOC_TARGET] SM%0d: alloc_target_sp changed SP%0d -> SP%0d (max_free_slots=%0d)",
                             cycles, sm, prev_alloc_target_sp,
                             dut.gen_sm_array[sm].u_sm.alloc_target_sp,
                             dut.gen_sm_array[sm].u_sm.max_free_slots);
                    prev_alloc_target_sp <= int'(dut.gen_sm_array[sm].u_sm.alloc_target_sp);
                end

                // l1_req_valid_int
                if (!prev_l1_req_valid_int && dut.gen_sm_array[sm].u_sm.l1_req_valid_int) begin
                    $display("[Cycle %0d] [ASSERT] SM%0d: l1_req_valid_int ASSERTED (addr=0x%08h, we=%b, wstrb=0x%02h, ready=%b)",
                             cycles, sm, dut.gen_sm_array[sm].u_sm.l1_req_addr_int,
                             dut.gen_sm_array[sm].u_sm.l1_req_we_int,
                             dut.gen_sm_array[sm].u_sm.l1_req_wstrb_int,
                             dut.gen_sm_array[sm].u_sm.l1_req_ready_int);
                end
                if (dut.gen_sm_array[sm].u_sm.l1_req_valid_int && dut.gen_sm_array[sm].u_sm.l1_req_ready_int) begin
                    $display("[Cycle %0d] [HANDSHAKE] SM%0d -> L1 Cache: REQ HANDSHAKE (addr=0x%08h, we=%b)",
                             cycles, sm, dut.gen_sm_array[sm].u_sm.l1_req_addr_int,
                             dut.gen_sm_array[sm].u_sm.l1_req_we_int);
                end
                prev_l1_req_valid_int <= dut.gen_sm_array[sm].u_sm.l1_req_valid_int;

                // l1_rsp_valid_int
                if (!prev_l1_rsp_valid_int && dut.gen_sm_array[sm].u_sm.l1_rsp_valid_int) begin
                    $display("[Cycle %0d] [ASSERT] SM%0d: l1_rsp_valid_int ASSERTED (rdata=0x%08h)",
                             cycles, sm, dut.gen_sm_array[sm].u_sm.l1_rsp_rdata_int[31:0]);
                end
                prev_l1_rsp_valid_int <= dut.gen_sm_array[sm].u_sm.l1_rsp_valid_int;

                // SM -> L2 interface
                if (!prev_sm_l1_req_valid && dut.gen_sm_array[sm].u_sm.l1_req_valid) begin
                    $display("[Cycle %0d] [ASSERT] SM%0d -> L2: l1_req_valid ASSERTED (addr=0x%08h, we=%b, ready=%b)",
                             cycles, sm, dut.gen_sm_array[sm].u_sm.l1_req_addr,
                             dut.gen_sm_array[sm].u_sm.l1_req_we,
                             dut.gen_sm_array[sm].u_sm.l1_req_ready);
                end
                if (dut.gen_sm_array[sm].u_sm.l1_req_valid && dut.gen_sm_array[sm].u_sm.l1_req_ready) begin
                    $display("[Cycle %0d] [HANDSHAKE] SM%0d -> L2: REQ HANDSHAKE (addr=0x%08h, we=%b)",
                             cycles, sm, dut.gen_sm_array[sm].u_sm.l1_req_addr,
                             dut.gen_sm_array[sm].u_sm.l1_req_we);
                end
                prev_sm_l1_req_valid <= dut.gen_sm_array[sm].u_sm.l1_req_valid;

                if (!prev_sm_l1_rsp_valid && dut.gen_sm_array[sm].u_sm.l1_rsp_valid) begin
                    $display("[Cycle %0d] [ASSERT] L2 -> SM%0d: l1_rsp_valid ASSERTED (rdata=0x%08h)",
                             cycles, sm, dut.gen_sm_array[sm].u_sm.l1_rsp_rdata[31:0]);
                end
                prev_sm_l1_rsp_valid <= dut.gen_sm_array[sm].u_sm.l1_rsp_valid;
            end
        end

        // Multi-SP specific monitors (gen_alloc_target_multi and gen_l1_arb_multi)
        if (NUM_SUB_PARTITIONS > 1) begin : mon_multi
            reg prev_arb_state;
            reg [$clog2(NUM_SUB_PARTITIONS)-1:0] prev_current_client;
            reg [$clog2(NUM_SUB_PARTITIONS)-1:0] prev_rr_ptr;
            reg prev_client_found;

            always @(posedge clk) begin
                if (!rst_n) begin
                    prev_arb_state      <= 1'b0;
                    prev_current_client <= '0;
                    prev_rr_ptr         <= '0;
                    prev_client_found   <= 1'b0;
                end else if (trace_arbiter) begin
                    if (dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.arb_state != prev_arb_state) begin
                        $display("[Cycle %0d] [L1_ARB_STATE] SM%0d: arb_state %s -> %s (current_client=%0d, sel_client=%0d, found=%b, rr_ptr=%0d, req_ready_int=%b, rsp_valid_int=%b)",
                                 cycles, sm,
                                 (prev_arb_state ? "ARB_BUSY" : "ARB_IDLE"),
                                 (dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.arb_state ? "ARB_BUSY" : "ARB_IDLE"),
                                 dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.current_client,
                                 dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.sel_client,
                                 dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.client_found,
                                 dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.rr_ptr,
                                 dut.gen_sm_array[sm].u_sm.l1_req_ready_int,
                                 dut.gen_sm_array[sm].u_sm.l1_rsp_valid_int);
                        prev_arb_state <= dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.arb_state;
                    end
                    if (dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.current_client != prev_current_client) begin
                        $display("[Cycle %0d] [L1_ARB_CLIENT] SM%0d: current_client %0d -> %0d (rr_ptr=%0d)",
                                 cycles, sm, prev_current_client,
                                 dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.current_client,
                                 dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.rr_ptr);
                        prev_current_client <= dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.current_client;
                    end
                    if (!prev_client_found && dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.client_found) begin
                        $display("[Cycle %0d] [ASSERT] SM%0d L1 Arbiter: client_found ASSERTED (sel_client=%0d, l1_req_ready_int=%b, arb_state=%s)",
                                 cycles, sm, dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.sel_client,
                                 dut.gen_sm_array[sm].u_sm.l1_req_ready_int,
                                 (dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.arb_state ? "ARB_BUSY" : "ARB_IDLE"));
                    end
                    prev_client_found <= dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.client_found;
                    prev_rr_ptr       <= dut.gen_sm_array[sm].u_sm.gen_l1_arb_multi.rr_ptr;
                end
            end
        end

        // SP-level monitors
        for (genvar sp = 0; sp < NUM_SUB_PARTITIONS; sp++) begin : mon_sp_block
            reg prev_sp_alloc_valid;
            reg [4:0] prev_sp_avail_slots;
            reg prev_sp_req_valid;
            reg prev_sp_rsp_valid;
            reg [1:0] prev_lsu_state;

            always @(posedge clk) begin
                if (!rst_n) begin
                    prev_sp_alloc_valid  <= 1'b0;
                    prev_sp_avail_slots  <= 5'd0;
                    prev_sp_req_valid    <= 1'b0;
                    prev_sp_rsp_valid    <= 1'b0;
                    prev_lsu_state       <= 2'd0;
                end else if (trace_arbiter) begin
                    // SP allocation valid assertion
                    if (!prev_sp_alloc_valid && dut.gen_sm_array[sm].u_sm.alloc[sp].valid) begin
                        $display("[Cycle %0d] [ASSERT] SM%0d SP%0d: alloc.valid ASSERTED (ready=%b, warp_cnt=%0d, thread_start=%0d, block_id=%0d)",
                                 cycles, sm, sp, dut.gen_sm_array[sm].u_sm.alloc[sp].ready,
                                 dut.gen_sm_array[sm].u_sm.warp_cnt,
                                 dut.gen_sm_array[sm].u_sm.alloc[sp].thread_id_start,
                                 dut.gen_sm_array[sm].u_sm.alloc[sp].block_id);
                    end
                    // Allocation handshake
                    if (dut.gen_sm_array[sm].u_sm.alloc[sp].valid && dut.gen_sm_array[sm].u_sm.alloc[sp].ready) begin
                        $display("[Cycle %0d] [HANDSHAKE] SM%0d SP%0d: ALLOC HANDSHAKE FIRE! (warp_cnt=%0d, thread_start=%0d, block=[%0d,%0d])",
                                 cycles, sm, sp, dut.gen_sm_array[sm].u_sm.warp_cnt,
                                 dut.gen_sm_array[sm].u_sm.alloc[sp].thread_id_start,
                                 dut.gen_sm_array[sm].u_sm.alloc[sp].block_idx_x,
                                 dut.gen_sm_array[sm].u_sm.alloc[sp].block_idx_y);
                    end
                    prev_sp_alloc_valid <= dut.gen_sm_array[sm].u_sm.alloc[sp].valid;

                    // SP available slots changed
                    if (dut.gen_sm_array[sm].u_sm.sp_avail_slots[sp] != prev_sp_avail_slots) begin
                        $display("[Cycle %0d] [SLOTS] SM%0d SP%0d: sp_avail_slots %0d -> %0d (ready=%b)",
                                 cycles, sm, sp, prev_sp_avail_slots,
                                 dut.gen_sm_array[sm].u_sm.sp_avail_slots[sp],
                                 dut.gen_sm_array[sm].u_sm.sp_alloc_ready[sp]);
                        prev_sp_avail_slots <= dut.gen_sm_array[sm].u_sm.sp_avail_slots[sp];
                    end

                    // SP L1 request valid assertion
                    if (!prev_sp_req_valid && dut.gen_sm_array[sm].u_sm.sp_l1_req_valid[sp]) begin
                        $display("[Cycle %0d] [ASSERT] SM%0d SP%0d: sp_l1_req_valid ASSERTED (addr=0x%08h, we=%b, wstrb=0x%02h, wdata=0x%08h, ready=%b)",
                                 cycles, sm, sp, dut.gen_sm_array[sm].u_sm.sp_l1_req_addr[sp],
                                 dut.gen_sm_array[sm].u_sm.sp_l1_req_we[sp],
                                 dut.gen_sm_array[sm].u_sm.sp_l1_req_wstrb[sp],
                                 dut.gen_sm_array[sm].u_sm.sp_l1_req_wdata[sp][31:0],
                                 dut.gen_sm_array[sm].u_sm.sp_l1_req_ready[sp]);
                    end
                    // SP L1 request handshake
                    if (dut.gen_sm_array[sm].u_sm.sp_l1_req_valid[sp] && dut.gen_sm_array[sm].u_sm.sp_l1_req_ready[sp]) begin
                        $display("[Cycle %0d] [HANDSHAKE] SM%0d SP%0d -> L1: REQ HANDSHAKE FIRE! (addr=0x%08h, we=%b)",
                                 cycles, sm, sp, dut.gen_sm_array[sm].u_sm.sp_l1_req_addr[sp],
                                 dut.gen_sm_array[sm].u_sm.sp_l1_req_we[sp]);
                    end
                    prev_sp_req_valid <= dut.gen_sm_array[sm].u_sm.sp_l1_req_valid[sp];

                    // SP L1 response valid assertion
                    if (!prev_sp_rsp_valid && dut.gen_sm_array[sm].u_sm.sp_l1_rsp_valid[sp]) begin
                        $display("[Cycle %0d] [ASSERT] SM%0d SP%0d <- L1: sp_l1_rsp_valid ASSERTED (rdata=0x%08h)",
                                 cycles, sm, sp, dut.gen_sm_array[sm].u_sm.sp_l1_rsp_rdata[sp][31:0]);
                    end
                    prev_sp_rsp_valid <= dut.gen_sm_array[sm].u_sm.sp_l1_rsp_valid[sp];

                    // LSU State
                    if (dut.gen_sm_array[sm].u_sm.gen_sub_partitions[sp].u_sp.u_sp_dpath.u_lsu.state != prev_lsu_state) begin
                        $display("[Cycle %0d] [LSU_STATE] SM%0d SP%0d: %s -> %s (fifo_cnt=%0d, req_valid=%b, req_ready=%b, rsp_valid=%b)",
                                 cycles, sm, sp,
                                 lsu_state_name(prev_lsu_state),
                                 lsu_state_name(dut.gen_sm_array[sm].u_sm.gen_sub_partitions[sp].u_sp.u_sp_dpath.u_lsu.state),
                                 dut.gen_sm_array[sm].u_sm.gen_sub_partitions[sp].u_sp.u_sp_dpath.u_lsu.fifo_count,
                                 dut.gen_sm_array[sm].u_sm.sp_l1_req_valid[sp],
                                 dut.gen_sm_array[sm].u_sm.sp_l1_req_ready[sp],
                                 dut.gen_sm_array[sm].u_sm.sp_l1_rsp_valid[sp]);
                        prev_lsu_state <= dut.gen_sm_array[sm].u_sm.gen_sub_partitions[sp].u_sp.u_sp_dpath.u_lsu.state;
                    end
                end
            end
        end
    end

    // AXI / DRAM Transactions Monitor
    always @(posedge clk) begin
        if (rst_n && trace_arbiter) begin
            if (dut.u_l2_cache.m_axi_arvalid && dut.u_l2_cache.m_axi_arready) begin
                $display("[Cycle %0d] [AXI_DRAM] READ ADDR HANDSHAKE: araddr=0x%08h arlen=%0d",
                         cycles, dut.u_l2_cache.m_axi_araddr, dut.u_l2_cache.m_axi_arlen);
            end
            if (dut.u_l2_cache.m_axi_rvalid && dut.u_l2_cache.m_axi_rready) begin
                $display("[Cycle %0d] [AXI_DRAM] READ DATA HANDSHAKE: rlast=%b",
                         cycles, dut.u_l2_cache.m_axi_rlast);
            end
            if (dut.u_l2_cache.m_axi_awvalid && dut.u_l2_cache.m_axi_awready) begin
                $display("[Cycle %0d] [AXI_DRAM] WRITE ADDR HANDSHAKE: awaddr=0x%08h awlen=%0d",
                         cycles, dut.u_l2_cache.m_axi_awaddr, dut.u_l2_cache.m_axi_awlen);
            end
            if (dut.u_l2_cache.m_axi_wvalid && dut.u_l2_cache.m_axi_wready) begin
                $display("[Cycle %0d] [AXI_DRAM] WRITE DATA HANDSHAKE: wlast=%b",
                         cycles, dut.u_l2_cache.m_axi_wlast);
            end
            if (dut.u_l2_cache.m_axi_bvalid && dut.u_l2_cache.m_axi_bready) begin
                $display("[Cycle %0d] [AXI_DRAM] WRITE RESP HANDSHAKE: bvalid=1",
                         cycles);
            end
        end
    end

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
            counters[PERF_L1_REQ] == 0 || counters[PERF_L2_REQ] == 0)
            $fatal(1, "Counter cache invariants mismatch");
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
        if (count == 0) $fatal(1, "Empty kernel");
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
        if (reads == 0 || writes == 0) $fatal(1, "Kernel did not exercise AXI VRAM reads/writes");
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
        $fwrite(counter_fd, "l1_req_count: %0d\n", counters[3]);
        $fwrite(counter_fd, "l1_hit_count: %0d\n", counters[4]);
        $fwrite(counter_fd, "l1_miss_count: %0d\n", counters[5]);
        $fwrite(counter_fd, "l2_req_count: %0d\n", counters[6]);
        $fwrite(counter_fd, "l2_hit_count: %0d\n", counters[7]);
        $fwrite(counter_fd, "l2_miss_count: %0d\n", counters[8]);
        $fwrite(counter_fd, "lsu_wait_cycles_count: %0d\n", counters[9]);
        $fwrite(counter_fd, "lsu_fifo_full_cycles_count: %0d\n", counters[10]);
        $fwrite(counter_fd, "axi_read_stall_cycles_count: %0d\n", counters[11]);
        $fwrite(counter_fd, "axi_write_stall_cycles_count: %0d\n", counters[12]);
        $fwrite(counter_fd, "warp_done_count: %0d\n", counters[13]);
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
