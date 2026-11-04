`timescale 1ns/1ps

// Stimulus and latency-aware reference model, shared by RTL and gate simulation.
module mul32_pattern (
    input  wire        clk,
    output reg  [31:0] a = 0,
    output reg  [31:0] b = 0,
    input  wire [31:0] result
);
    reg [31:0] previous_product;
    reg valid = 0;
    integer checks = 0;
    integer seed = 32'h145ab;
    // Sample after NBA updates; each result belongs to the previous transaction.
    task automatic drive(input [31:0] x, y);
        begin
            @(negedge clk);
            a = x; b = y;
            @(posedge clk); #1;
            if (valid) begin
                if (result !== previous_product)
                    $fatal(1, "Mismatch: got %h expected %h", result, previous_product);
                checks = checks + 1;
            end
            previous_product = x * y;
            valid = 1;
        end
    endtask
    initial begin
        drive(0, 0);
        drive(32'hffffffff, 32'hffffffff);
        drive(32'h80000000, 2);
        drive(32'hffff0000, 32'h0000ffff);
        drive(32'h00010000, 32'h00010000);
        drive(32'h7fffffff, 32'h7fffffff);
        for (integer i = 0; i < 32; i = i + 1) begin
            drive(32'b1 << i, 32'hffffffff);
            drive(32'hffffffff, 32'b1 << i);
        end
        repeat (2000) drive($random(seed), $random(seed));
        drive(0, 0);
        $display("PASS: %0d products, two pipeline stages", checks);
        $finish;
    end
endmodule
