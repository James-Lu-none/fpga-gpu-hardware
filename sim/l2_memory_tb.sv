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
    task automatic write_csr(input [31:0] address, input [31:0] data, input bit data_first);
        if (data_first) begin
            @(negedge clk); ctrl.wvalid = 1; ctrl.wdata = data; ctrl.wstrb = 15;
            do @(posedge clk); while (!ctrl.wready);
            @(negedge clk); ctrl.wvalid = 0;
            repeat (3) @(negedge clk);
            ctrl.awvalid = 1; ctrl.awaddr = address;
            do @(posedge clk); while (!ctrl.awready);
            @(negedge clk); ctrl.awvalid = 0;
        end else begin
            @(negedge clk); ctrl.awvalid = 1; ctrl.awaddr = address;
            do @(posedge clk); while (!ctrl.awready);
            @(negedge clk); ctrl.awvalid = 0;
            repeat (3) @(negedge clk);
            ctrl.wvalid = 1; ctrl.wdata = data; ctrl.wstrb = 15;
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
    task automatic seed_and_check(input integer run_number, input integer path);
        reg [31:0] status, lines, run_id;
        integer before_writes, expected_requests, expected_writes;
        expected_requests = path == 0 ? 128 : (path == 1 || path == 3) ? 512 : 1024;
        expected_writes = path == 0 ? 128 : path == 1 ? 512 : 1024;
        before_writes = writes;
        write_csr('h20024, 32'(path), path[0]);
        for (int i = 0; i < 8192; i++) memory.memory[i] = 64'ha5a5a5a5a5a5a5a5;
        write_csr('h20014, 1, run_number[0]);
        do read_csr('h20018, status); while ((status & 3) != 2);
        read_csr('h2001c, lines);
        read_csr('h20020, run_id);
        if (status != 2 || lines != 32'(expected_requests) || run_id != 32'(run_number) || busy ||
            writes - before_writes != expected_writes || reads != 0)
            $fatal(1, "Invalid completion status=%h lines=%0d run=%0d", status, lines, run_id);
        for (int i = 0; i < 16384; i++) begin
            reg [31:0] expected_word, actual_word;
            expected_word = (i >= 1024 && i < 2048) ? (32'h4c320000 ^ 32'(i-1024)) : 32'ha5a5a5a5;
            actual_word = memory.memory[i/2][(i%2)*32 +: 32];
            if (actual_word != expected_word)
                $fatal(1, "Memory mismatch byte address=%h expected=%h actual=%h", i*4, expected_word, actual_word);
        end
        read_csr('h20030, status);
        if (status != (path == 0 ? 0 : 'h1000)) $fatal(1, "Incorrect first L1 address");
        read_csr('h20034, status);
        if (status != 'h1000) $fatal(1, "Incorrect first L2 address");
        read_csr('h20038, status);
        if (status != 'h1000) $fatal(1, "Incorrect first AXI address");
        read_csr('h2003c, status);
        if (status != (path == 0 ? 6 : 7)) $fatal(1, "Missing address snapshot");
        $display("PASS: path=%0d run=%0d requests=%0d AXI writes=%0d; full 64 KiB and snapshots checked",
                 path, run_number, expected_requests, expected_writes);
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
        read_csr('h20028, value);
        if (value != 'h3f) $fatal(1, "Missing path capabilities");
        for (int round = 0; round < 2; round++)
            for (int path = 0; path < 6; path++) seed_and_check(round*6 + path + 1, path);
        // Exercise the actual AXI-Lite route into the VRF probe.
        read_csr('h20040, value);
        if (value != 'h56524631) $fatal(1, "Missing VRF probe");
        read_csr('h20080, value);
        if (value != 'h20820) $fatal(1, "Unexpected VRF geometry");
        write_csr('h20048, 1, 0); // warp 0, R1
        write_csr('h2004c, 3, 0);
        write_csr('h20050, 'h1000, 0);
        write_csr('h20054, 'h12345678, 1);
        write_csr('h20044, 1, 0);
        read_csr('h20044, value);
        if (value != 1) $fatal(1, "VRF write not acknowledged");
        write_csr('h20058, (1 << 5) | 1, 0);
        write_csr('h2005c, 'habc12345, 1);
        write_csr('h20044, 2, 0);
        read_csr('h20060, value);
        if (value != 1) $fatal(1, "Missing VRF snapshot");
        read_csr('h20064, value);
        if (value != 'h1000) $fatal(1, "Incorrect VRF rs1 lane 0");
        read_csr('h20068, value);
        if (value != 'h12345678) $fatal(1, "Incorrect VRF rs1 lane 1");
        read_csr('h2006c, value);
        if (value != 'h1000) $fatal(1, "Incorrect VRF rs2 lane 0");
        read_csr('h20070, value);
        if (value != 'h12345678) $fatal(1, "Incorrect VRF rs2 lane 1");
        read_csr('h20074, value);
        if (value != 'h345) $fatal(1, "Incorrect VRF PC/warp snapshot");
        read_csr('h20078, value);
        if (value != 'habc12345) $fatal(1, "Incorrect VRF tag snapshot");
        read_csr('h2007c, value);
        if (value != 'ha10003) $fatal(1, "Incorrect VRF flags snapshot");
        $display("PASS: AXI-Lite VRF write, read, counters and operand snapshots");
        write_csr('h20024, 0, 0);
        force memory_bus.bresp = 2'b10;
        write_csr('h20014, 1, 0);
        do read_csr('h20018, value); while ((value & 3) != 2);
        if (value != 6) $fatal(1, "AXI error not recorded: %h", value);
        release memory_bus.bresp;
        $display("PASS: AXI write response errors recorded");
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1, "L2 diagnostic timed out");
    end
endmodule
