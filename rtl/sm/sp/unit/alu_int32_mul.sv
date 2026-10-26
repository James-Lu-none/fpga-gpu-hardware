`timescale 1ns / 1ps
// Two-cycle, fully pipelined low-32-bit multiply. Signed and unsigned low
// products are identical modulo 2^32. Payload is qualified by external valid.
module alu_int32_mul (
    input wire clk,
    input wire [31:0] a, b,
    output reg [31:0] result
);
    (* use_dsp = "yes" *) reg [31:0] low_product;
    (* use_dsp = "yes" *) reg [15:0] cross_ab, cross_ba;
    wire [15:0] cross_sum = cross_ab + cross_ba;
    always @(posedge clk) begin
        low_product <= a[15:0] * b[15:0];
        cross_ab <= a[31:16] * b[15:0];
        cross_ba <= a[15:0] * b[31:16];
        result <= low_product + {cross_sum, 16'b0};
    end
endmodule
