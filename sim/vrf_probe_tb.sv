`timescale 1ns / 1ps
// Flat-port testbench shared by RTL and the exported Vivado functional netlist.
module vrf_probe_tb;
    reg clk = 0, rst_n = 0, write_enable = 0;
    reg [7:0] write_addr = 0, read_addr = 0;
    reg [31:0] write_data = 0;
    wire [31:0] read_data;
    reg [31:0] golden [0:7][0:31][0:1];
    integer checks = 0;
    vrf_probe dut(.clk(clk), .rst_n(rst_n), .write_enable(write_enable),
                  .write_addr(write_addr), .read_addr(read_addr), .write_data(write_data), .read_data(read_data));
    always #4 clk = !clk;
    task automatic wr(input [7:0] address, input [31:0] data);
        @(negedge clk); write_addr = address; write_data = data; write_enable = 1;
        @(negedge clk); write_enable = 0;
    endtask
    task automatic rd(input [7:0] address, output [31:0] data);
        @(negedge clk); read_addr = address;
        #1; data = read_data;
    endtask
    task automatic wait_count(input [7:0] address, input [31:0] before_count);
        reg [31:0] count;
        for (int i = 0; i < 20; i++) begin
            rd(address, count);
            if (count === before_count + 1) return;
        end
        $fatal(1, "VRF counter timeout offset=%h before=%h actual=%h", address, before_count, count);
    endtask
    task automatic put_reg(input integer warp, reg_index, mask, input [31:0] lo, hi);
        reg [31:0] before_count;
        rd('h44, before_count);
        wr('h48, 32'((warp << 5) | reg_index));
        wr('h4c, 32'(mask)); wr('h50, lo); wr('h54, hi); wr('h44, 1);
        wait_count('h44, before_count);
        if (reg_index != 0) begin
            if (mask & 1) golden[warp][reg_index][0] = lo;
            if (mask & 2) golden[warp][reg_index][1] = hi;
        end
    endtask
    task automatic check_regs(input integer warp, rs1, rs2);
        reg [31:0] before_count, tag, value, raw[0:3], data[0:3], select;
        rd('h60, before_count);
        tag = 32'habc00000 + 32'(checks) + 1;
        wr('h58, 32'((warp << 10) | (rs2 << 5) | rs1)); wr('h5c, tag); wr('h44, 2);
        wait_count('h60, before_count);
        rd('h64, data[0]); rd('h68, data[1]); rd('h6c, data[2]); rd('h70, data[3]);
        rd('h88, select);
        rd('h8c, raw[0]); rd('h90, raw[1]); rd('h94, raw[2]); rd('h98, raw[3]);
        if (data[0] !== golden[warp][rs1][0] || data[1] !== golden[warp][rs1][1] ||
            data[2] !== golden[warp][rs2][0] || data[3] !== golden[warp][rs2][1] ||
            (rs1 != 0 && (raw[0] !== golden[warp][rs1][0] || raw[1] !== golden[warp][rs1][1])) ||
            (rs2 != 0 && (raw[2] !== golden[warp][rs2][0] || raw[3] !== golden[warp][rs2][1])) ||
            select !== 32'((warp << 5) | rs1 | (((warp << 5) | rs2) << 8) |
                          (rs1 == 0 ? 'h10000 : 0) | (rs2 == 0 ? 'h20000 : 0)))
            $fatal(1, "VRF warp=%0d rs1=R%0d data=[%h,%h] expected=[%h,%h] raw=[%h,%h]; rs2=R%0d data=[%h,%h] expected=[%h,%h] raw=[%h,%h]; select=%h",
                   warp, rs1, data[0], data[1], golden[warp][rs1][0], golden[warp][rs1][1], raw[0], raw[1],
                   rs2, data[2], data[3], golden[warp][rs2][0], golden[warp][rs2][1], raw[2], raw[3], select);
        rd('h74, value);
        if (value !== 32'((warp << 16) | (tag & 'hfff))) $fatal(1, "VRF metadata mismatch");
        rd('h78, value);
        if (value !== tag) $fatal(1, "VRF tag mismatch");
        rd('h7c, value);
        if (value !== 'ha10003) $fatal(1, "VRF flags mismatch");
        checks++;
    endtask
    initial begin
        reg [31:0] value, pattern;
        for (int w = 0; w < 8; w++)
            for (int r = 0; r < 32; r++)
                for (int lane = 0; lane < 2; lane++) golden[w][r][lane] = 0;
        // Allow the UNISIM glbl startup GSR to finish before driving commands.
        repeat (30) @(negedge clk);
        rst_n = 1;
        rd('h40, value);
        if (value !== 'h56524631) $fatal(1, "Missing VRF probe");
        for (int w = 0; w < 8; w++)
            for (int r = 1; r < 32; r++) begin
                pattern = 32'h13570000 ^ 32'(w << 12) ^ 32'(r << 4);
                put_reg(w, r, 3, pattern, ~pattern);
            end
        for (int w = 0; w < 8; w++) begin
            put_reg(w, 0, 3, 'hffffffff, 'hffffffff);
            check_regs(w, 1, 1);
            for (int r = 0; r < 32; r++) check_regs(w, r, (r+1)%32);
            for (int r = 1; r < 32; r++) begin
                put_reg(w, r, 1, 32'h24680000 ^ 32'(w << 12) ^ 32'(r), 'hdeadbeef);
                check_regs(w, r, r);
                put_reg(w, r, 2, 'hdeadbeef, 32'h89ab0000 ^ 32'(w << 12) ^ 32'(r));
                check_regs(w, r, (r+1)%32);
            end
            put_reg(w, 1, 0, 'hdeadbeef, 'hdeadbeef);
        end
        for (int w = 0; w < 8; w++)
            for (int r = 0; r < 32; r++) check_regs(w, (r+1)%32, r);
        $display("PASS: VRF probe functional test; %0d snapshots, both ports, raw BRAM, R0 selection, masks and metadata", checks);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "VRF probe functional test timed out");
    end
endmodule
