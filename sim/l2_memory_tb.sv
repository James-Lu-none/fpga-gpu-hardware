`timescale 1ns / 1ps
module l2_memory_tb;
    reg clk = 0, rst_n = 0;
    always #4 clk = !clk;
    axi_lite_if ctrl();
    axi4_if memory_bus();
    // Same GPU-side AXI attributes as rtl/top.sv.
    assign memory_bus.awid = 0;
    assign memory_bus.awlock = 0;
    assign memory_bus.awcache = 3;
    assign memory_bus.awprot = 0;
    assign memory_bus.awqos = 0;
    assign memory_bus.awregion = 0;
    assign memory_bus.arid = 0;
    assign memory_bus.arlock = 0;
    assign memory_bus.arcache = 3;
    assign memory_bus.arprot = 0;
    assign memory_bus.arqos = 0;
    assign memory_bus.arregion = 0;
    wire busy;
    integer reads, writes;
    l2_memory_test dut(.clk(clk), .rst_n(rst_n), .s_axi_lite(ctrl), .m_axi(memory_bus), .busy(busy));
    axi_vram_model memory(.clk(clk), .rst_n(rst_n), .bus(memory_bus), .reads(reads), .writes(writes));

    // Exercise independent AXI-Lite AW/W arrival and response backpressure.
    task automatic write_start(input bit data_first);
        if (data_first) begin
            @(negedge clk); ctrl.wvalid = 1; ctrl.wdata = 1; ctrl.wstrb = 15;
            do @(posedge clk); while (!ctrl.wready);
            @(negedge clk); ctrl.wvalid = 0;
            repeat (3) @(negedge clk);
            ctrl.awvalid = 1; ctrl.awaddr = 'h20014;
            do @(posedge clk); while (!ctrl.awready);
            @(negedge clk); ctrl.awvalid = 0;
        end else begin
            @(negedge clk); ctrl.awvalid = 1; ctrl.awaddr = 'h20014;
            do @(posedge clk); while (!ctrl.awready);
            @(negedge clk); ctrl.awvalid = 0;
            repeat (3) @(negedge clk);
            ctrl.wvalid = 1; ctrl.wdata = 1; ctrl.wstrb = 15;
            do @(posedge clk); while (!ctrl.wready);
            @(negedge clk); ctrl.wvalid = 0;
        end
        wait (ctrl.bvalid);
        repeat (3) begin
            @(negedge clk);
            if (!ctrl.bvalid || ctrl.bresp != 0) $fatal(1, "Write response lost under backpressure");
        end
        ctrl.bready = 1;
        @(posedge clk); @(negedge clk); ctrl.bready = 0;
    endtask
    task automatic read_csr(input [31:0] address, output [31:0] value);
        @(negedge clk); ctrl.arvalid = 1; ctrl.araddr = address;
        do @(posedge clk); while (!ctrl.arready);
        @(negedge clk); ctrl.arvalid = 0;
        wait (ctrl.rvalid);
        value = ctrl.rdata;
        repeat (3) begin
            @(negedge clk);
            if (!ctrl.rvalid || ctrl.rdata != value) $fatal(1, "Read response lost under backpressure");
        end
        ctrl.rready = 1;
        @(posedge clk); @(negedge clk); ctrl.rready = 0;
    endtask
    task automatic seed_and_check(input integer run_number);
        reg [31:0] status, lines, run_id;
        integer before_writes;
        before_writes = writes;
        for (int i = 0; i < 8192; i++) memory.memory[i] = 64'ha5a5a5a5a5a5a5a5;
        write_start(run_number == 2);
        do read_csr('h20018, status); while ((status & 3) != 2);
        read_csr('h2001c, lines);
        read_csr('h20020, run_id);
        if (status != 2 || lines != 128 || run_id != 32'(run_number) || busy ||
            writes - before_writes != 128 || reads != 0)
            $fatal(1, "Invalid completion status=%h lines=%0d run=%0d", status, lines, run_id);
        for (int i = 0; i < 16384; i++) begin
            reg [31:0] expected_word, actual_word;
            expected_word = (i >= 1024 && i < 2048) ? (32'h4c320000 ^ 32'(i-1024)) : 32'ha5a5a5a5;
            actual_word = memory.memory[i/2][(i%2)*32 +: 32];
            if (actual_word != expected_word)
                $fatal(1, "Memory mismatch byte address=%h expected=%h actual=%h", i*4, expected_word, actual_word);
        end
        $display("PASS: L2 run %0d, 128 acknowledged writes, full 64 KiB memory checked", run_number);
    endtask
    initial begin
        reg [31:0] value;
        ctrl.awvalid = 0; ctrl.wvalid = 0; ctrl.bready = 0;
        ctrl.arvalid = 0; ctrl.rready = 0;
        ctrl.awaddr = 0; ctrl.awprot = 0; ctrl.wdata = 0; ctrl.wstrb = 0;
        ctrl.araddr = 0; ctrl.arprot = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        read_csr('h20010, value);
        if (value != 'h4c325453) $fatal(1, "Invalid diagnostic magic");
        seed_and_check(1);
        seed_and_check(2);
        force memory_bus.bresp = 2'b10;
        write_start(0);
        do read_csr('h20018, value); while ((value & 3) != 2);
        if (value != 6) $fatal(1, "AXI error not recorded: %h", value);
        release memory_bus.bresp;
        $display("PASS: AXI write response errors recorded");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "L2 diagnostic timed out");
    end
endmodule
