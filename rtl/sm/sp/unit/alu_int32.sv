`timescale 1ns / 1ps
// Combinational 32-bit scalar lane. fn: 0 ADD, 1 SUB, 2 MUL (low 32), 3 zero.
// ISA decode, immediates, S2R, warp metadata and pipeline registers belong to SP.
module alu_int32 (
    input wire [2:0] fn,
    input wire [31:0] a, b,
    output reg [31:0] result,
    output wire [2:0] nzp
);
    always @(*) begin
        case (fn)
            3'd0: result = a + b;
            3'd1: result = a - b;
            3'd2: result = a * b;
            default: result = 32'd0;
        endcase
    end
    assign nzp = {result[31], result == 0, !result[31] && result != 0};
endmodule
