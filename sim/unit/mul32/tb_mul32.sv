`timescale 1ns/1ps

// Test harness: clock generation, DUT wiring and simulation watchdog.
module tb_mul32;
    reg clk = 0;
    always #5 clk = ~clk;

    wire [31:0] a, b;
    wire [31:0] result;

    alu_int32_mul dut (
        .clk(clk),
        .a(a),
        .b(b),
        .result(result)
    );

    mul32_pattern pattern (
        .clk(clk),
        .a(a),
        .b(b),
        .result(result)
    );

    initial begin
        #100000;
        $fatal(1, "Timeout: mul32 test did not finish within 100 us");
    end
endmodule
